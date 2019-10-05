# frozen_string_literal: true

require 'autoproj/daemon/pull_request_cache'
require 'autoproj/daemon/package_repository'
require 'autoproj/daemon/github/client'
require 'autoproj/daemon/github/branch'
require 'autoproj/daemon/github/pull_request'
require 'yaml'

module Autoproj
    module Daemon
        # This class synchronizes the automatically created branches
        # representing open Pull Requests to the actual Pull Requests
        # on each watched repository
        class BuildconfManager
            # @return [Autoproj::PackageRepository]
            attr_reader :buildconf

            # @return [Github::Client]
            attr_reader :client

            # @return [PullRequestCache]
            attr_reader :cache

            # @return [Array<Autoproj::Daemon::PackageRepository>]
            attr_reader :packages

            # @return [Array<Github::Branch>]
            attr_reader :branches

            # @return [Array<Github::PullRequest>]
            attr_reader :pull_requests

            # @return [Autoproj::Workspace]
            attr_reader :ws

            # @param [PackageRepository] buildconf Buildconf repository
            # @param [Github::Client] client Github client API
            # @param [Array<Autoproj::Daemon::PackageRepository>] packages An array
            #     with all package repositories to watch
            # @param [Autoproj::Daemon::PullRequestCache] cache Pull request cache
            # @param [Autoproj::Workspace] workspace Current workspace
            def initialize(buildconf, client, packages, cache, workspace)
                @buildconf = buildconf
                @client = client
                @packages = packages
                @pull_requests = []
                @branches = []
                @ws = workspace
                @main = ws.manifest.main_package_set.create_autobuild_package
                @importer = @main.importer
                @cache = cache
            end

            # @return [Array<Github::PullRequest>]
            def update_pull_requests
                @pull_requests = []
                filtered_repos = packages.map do |pkg|
                    { owner: pkg.owner, name: pkg.name, branch: pkg.branch }
                end.uniq

                filtered_repos.each do |repo|
                    @pull_requests << client.pull_requests(
                        repo[:owner],
                        repo[:name],
                        base: repo[:branch],
                        state: 'open'
                    )
                end
                @pull_requests.flatten!
                @pull_requests.compact!
                @pull_requests
            end

            BRANCH_TO_PR_RX =
                %r{autoproj/([A-Za-z\d\-_]+)/([A-Za-z\d\-_]+)/pulls/(\d+)}.freeze

            # @return [Array<Github::Branch>]
            def update_branches
                @branches = client.branches(
                    buildconf.owner,
                    buildconf.name
                )
            end

            # @return [nil]
            def delete_stale_branches
                stale_branches = branches.select do |branch|
                    next false unless (m = branch.branch_name.match(BRANCH_TO_PR_RX))

                    pull_requests.none? do |pr|
                        pr.base_owner == m[1] &&
                            pr.base_name == m[2] && pr.number == m[3].to_i
                    end
                end
                delete_branches(stale_branches)
            end

            # @return [nil]
            def delete_branches(branches)
                branches.each do |branch|
                    Autoproj.message "Deleting stale branch #{branch.branch_name} "\
                        "from #{branch.owner}/#{branch.name}"
                    client.delete_branch(branch)
                end
                nil
            end

            # @return [String]
            def branch_name_by_pull_request(pull_request)
                "autoproj/#{pull_request.base_owner}/"\
                    "#{pull_request.base_name}/pulls/#{pull_request.number}"
            end

            # @return [(Array<Github::Branch>, Array<Github::Branch>)]
            def create_missing_branches
                created = []
                existing = []

                pull_requests.each do |pr|
                    branch_name = branch_name_by_pull_request(pr)
                    found_branch =
                        branches.find { |branch| branch.branch_name == branch_name }

                    if found_branch
                        existing << found_branch
                    else
                        Autoproj.message "Creating branch #{branch_name} "\
                            "on #{buildconf.owner}/#{buildconf.name}"
                        created << create_branch_for_pr(branch_name, pr)
                    end
                end

                [created, existing]
            end

            OVERRIDES_COMMIT_MSG = 'Update PR overrides'
            OVERRIDES_FILE = File.join(
                Autoproj::Workspace::OVERRIDES_DIR,
                '999-autoproj.yml'
            ).freeze

            # @param [Github::PullRequest] pull_request
            # @return [Github::Branch]
            def create_branch_for_pr(branch_name, pull_request)
                overrides = overrides_for_pull_request(pull_request)
                commit_id =
                    Autoproj::Ops::Snapshot.create_commit(
                        @main, OVERRIDES_FILE, OVERRIDES_COMMIT_MSG, real_author: false
                    ) do |io|
                        YAML.dump(overrides, io)
                    end

                @importer.run_git_bare(
                    @main,
                    'update-ref',
                    '-m',
                    OVERRIDES_COMMIT_MSG,
                    "refs/heads/#{branch_name}",
                    commit_id
                )
                @importer.run_git_bare(
                    @main, 'push', '-fu', @importer.remote_name, branch_name
                )

                created = client.branch(buildconf.owner, buildconf.name, branch_name)
                cache.add(pull_request, overrides)
                created
            end

            # @param [Github::PullRequest] pull_request
            # @return [Array<PackageRepository>]
            def packages_affected_by_pull_request(pull_request)
                packages.select do |pkg|
                    pkg.name == pull_request.base_name &&
                        pkg.owner == pull_request.base_owner &&
                        pkg.branch == pull_request.base_branch
                end
            end

            # @param [Github::PullRequest] pull_request
            # @return [Hash]
            def overrides_for_pull_request(pull_request)
                # TODO: Extract overrides from PR body.
                #    This is not as easy as one could have thought
                #    because the depended upon PR may have dependencies
                #    of its own. We have to do it recursively. Detecting
                #    changes in this chain of overrides is even more
                #    challenging. Or, one could add the entire dependency
                #    tree in every PR body.
                packages_affected_by_pull_request(pull_request).map do |pkg|
                    key = if pkg.package_set?
                              "pkg_set:#{pkg.vcs[:repository_id]}"
                          else
                              pkg.package
                          end
                    {
                        key => {
                            'github' => "#{pull_request.head_owner}/"\
                                        "#{pull_request.head_name}",
                            'remote_branch' => pull_request.head_branch
                        }
                    }
                end
            end

            # @param [Github::Branch] branch
            # @return [Github::PullRequest, nil]
            def pull_request_by_branch(branch)
                pull_requests.find do |pr|
                    branch_name_by_pull_request(pr) == branch.branch_name
                end
            end

            # @param [Github::Branch] branch
            # @return [nil]
            def trigger_build(branch)
                Autoproj.message "Triggering build for #{branch.branch_name} (new)"
                nil
            end

            # @param [Array<Github::Branch>] branches
            # @return [nil]
            def trigger_build_if_branch_changed(branches)
                branches.each do |branch|
                    pr = pull_request_by_branch(branch)
                    overrides = overrides_for_pull_request(pr)
                    next unless cache.changed?(pr, overrides)

                    cache.add(pr, overrides)
                    Autoproj.message "Triggering build for #{branch.branch_name} (update)"
                end
                nil
            end

            # @return [nil]
            def synchronize_branches
                cache.clear
                update_pull_requests
                update_branches
                delete_stale_branches
                created, existing = create_missing_branches

                created.each { |branch| trigger_build(branch) }
                trigger_build_if_branch_changed(existing)
                cache.dump
            end
        end
    end
end
