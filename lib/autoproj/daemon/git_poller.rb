# frozen_string_literal: true

require "autoproj/daemon/buildbot"
require "autoproj/daemon/pull_request_cache"
require "autoproj/daemon/package_repository"
require "autoproj/daemon/github/client"
require "autoproj/daemon/github/branch"
require "autoproj/daemon/github/pull_request"
require "autoproj/daemon/overrides_retriever"
require "date"
require "yaml"

module Autoproj
    module Daemon
        # This class synchronizes the automatically created branches
        # representing open Pull Requests to the actual Pull Requests
        # on each watched repository
        class GitPoller
            # @return [Autoproj::Daemon::Buildbot]
            attr_reader :bb

            # @return [Autoproj::Daemon::PackageRepository]
            attr_reader :buildconf

            # @return [Github::Client]
            attr_reader :client

            # @return [PullRequestCache]
            attr_reader :cache

            # @return [Array<Autoproj::Daemon::PackageRepository>]
            attr_reader :packages

            # @return [Array<Github::Branch>]
            attr_reader :branches

            # @return [Array<Github::Branch>]
            attr_reader :package_branches

            # @return [Array<Github::PullRequest>]
            attr_reader :pull_requests

            # @return [Array<Github::PullRequest>]
            attr_reader :pull_requests_stale

            # @return [Autoproj::Workspace]
            attr_reader :ws

            # @return [Autoproj::Daemon::WorkspaceUpdater]
            attr_reader :updater

            # @param [PackageRepository] buildconf Buildconf repository
            # @param [Github::Client] client Github client API
            # @param [Array<Autoproj::Daemon::PackageRepository>] packages An array
            #     with all package repositories to watch
            # @param [Autoproj::Daemon::PullRequestCache] cache Pull request cache
            # @param [Autoproj::Workspace] workspace Current workspace
            def initialize(
                buildconf, client, packages, cache, workspace, updater, project: "daemon"
            )
                @updater = updater
                @project = project.to_str
                @bb = Buildbot.new(workspace, project: project)
                @buildconf = buildconf
                @client = client
                @packages = packages
                @pull_requests = []
                @pull_requests_stale = []
                @branches = []
                @package_branches = []
                @ws = workspace
                @main = @buildconf.autobuild
                @importer = @main.importer
                @cache = cache
            end

            # @return [void]
            def clear_and_dump_cache
                @cache.clear
                @cache.dump
            end

            # @return [Array<Autoproj::Daemon::PackageRepository>]
            def unique_packages
                packages.uniq do |pkg|
                    [pkg.owner, pkg.name, pkg.branch]
                end
            end

            # @return [Array<Github::Branch>]
            def update_package_branches
                filtered_repos = unique_packages
                Autoproj.message "Fetching branches from "\
                    "#{filtered_repos.size} repositories..."

                @package_branches = filtered_repos.flat_map do |pkg|
                    client.branch(pkg.owner, pkg.name, pkg.branch)
                end

                Autoproj.message "Tracking #{package_branches.size} branches"
                package_branches
            end

            # @param [Github::Branch] branch
            # @return [Array<Autoproj::Daemon::PackageRepository>]
            def packages_by_branch(branch)
                packages.select do |pkg|
                    pkg.name == branch.name &&
                        pkg.owner == branch.owner &&
                        pkg.branch == branch.branch_name
                end
            end

            # @return [Boolean]
            def trigger_build_if_packages_changed
                changed = false

                package_branches.each do |branch|
                    pkgs = packages_by_branch(branch)
                    pkgs.each do |pkg|
                        next if pkg.head_sha == branch.sha

                        Autoproj.message(
                            "Push detected on #{pkg.package}, local: #{pkg.head_sha} "\
                            "remote: #{branch.sha}"
                        )

                        if updater.update_failed?
                            Autoproj.message "Not triggering build, last update failed"
                            Autoproj.message "The daemon will attempt to update the "\
                                             "workspace, and will trigger a new build "\
                                             "if that's successful"
                        else
                            bb.post_mainline_changes(pkg, branch)
                        end
                        changed = true
                    end
                end

                changed
            end

            # @return [Boolean]
            def trigger_build_if_buildconf_changed
                buildconf_branch = client.branch(
                    buildconf.owner, buildconf.name, buildconf.branch
                )
                return false if buildconf.head_sha == buildconf_branch.sha

                Autoproj.message(
                    "Push detected on the buildconf, local: #{buildconf.head_sha} "\
                    "remote: #{buildconf_branch.sha}"
                )
                bb.post_mainline_changes(buildconf, buildconf_branch)
                true
            end

            # @return [void]
            def handle_mainline_changes
                pkgs_changed = trigger_build_if_packages_changed
                buildconf_changed = trigger_build_if_buildconf_changed

                clear_and_dump_cache if buildconf_changed
                return unless pkgs_changed || buildconf_changed

                updater.restart_and_update
            end

            # @return [Array<Github::PullRequest>]
            def update_pull_requests
                filtered_repos = unique_packages
                Autoproj.message "Fetching pull requests from "\
                    "#{filtered_repos.size} repositories..."

                @pull_requests = filtered_repos.flat_map do |pkg|
                    client.pull_requests(
                        pkg.owner,
                        pkg.name,
                        base: pkg.branch,
                        state: "open"
                    )
                end
                @pull_requests, @pull_requests_stale = @pull_requests.partition do |pr|
                    (Time.now.to_date - pr.updated_at.to_date)
                        .round < ws.config.daemon_max_age
                end

                total_repos = pull_requests.size + pull_requests_stale.size
                Autoproj.message "Tracking #{total_repos} pull requests "\
                    "(#{pull_requests_stale.size} stale)"

                @pull_requests
            end

            BuildconfBranch = Struct.new :project, :owner, :repository, :pull_id

            # Parse the buildconf ref into the info it contains
            #
            # The pattern autoproj/PROJECT/OWNER/REPO/pulls/ID, matching
            # what {#branch_name_by_pull_request} does.
            #
            # @return [BuildconfBranch,nil] the info, or nil if the branch
            #    name does not match the expected pattern
            def parse_buildconf_branch(branch)
                elements = branch.split("/")
                return unless elements.size == 6
                return unless elements[0] == "autoproj"
                return unless elements[4] == "pulls"

                pull_id =
                    begin
                        Float(elements[5])
                    rescue ArgumentError
                        return
                    end

                BuildconfBranch.new(elements[1], elements[2], elements[3], pull_id)
            end

            # @return [Array<Github::Branch>]
            def update_branches
                @branches = client.branches(
                    buildconf.owner,
                    buildconf.name
                )
            end

            # @return [void]
            def delete_stale_branches
                stale_branches = branches.select do |branch|
                    branch_info = parse_buildconf_branch(branch.branch_name)
                    unless branch_info
                        # Delete branches under autoproj/ that do not match
                        # the expected pattern (i.e. old stale branches before
                        # we changed the pattern)
                        next branch.branch_name.start_with?("autoproj/")
                    end

                    next false unless branch_info.project == @project

                    pull_requests.none? do |pr|
                        pr.base_owner == branch_info.owner &&
                            pr.base_name == branch_info.repository &&
                            pr.number == branch_info.pull_id
                    end
                end
                delete_branches(stale_branches)
            end

            # @return [void]
            def delete_branches(branches)
                branches.each do |branch|
                    Autoproj.message "Deleting stale branch #{branch.branch_name} "\
                        "from #{branch.owner}/#{branch.name}"
                    client.delete_branch(branch)
                end
            end

            # @return [String]
            def self.branch_name_by_pull_request(project, pull_request)
                "autoproj/#{project}/#{pull_request.base_owner}/"\
                    "#{pull_request.base_name}/pulls/#{pull_request.number}"
            end

            def branch_name_by_pull_request(pull_request)
                self.class.branch_name_by_pull_request(@project, pull_request)
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

            OVERRIDES_COMMIT_MSG = "Update PR overrides"
            OVERRIDES_FILE = File.join(
                Autoproj::Workspace::OVERRIDES_DIR,
                "999-autoproj.yml"
            ).freeze

            # @param [String] branch_name
            # @param [Array<Hash>] overrides
            # @return [Github::Branch]
            def commit_and_push_overrides(branch_name, overrides)
                commit_id =
                    Autoproj::Ops::Snapshot.create_commit(
                        @main, OVERRIDES_FILE, OVERRIDES_COMMIT_MSG, real_author: false
                    ) do |io|
                        YAML.dump(overrides, io)
                    end
                @importer.run_git_bare(
                    @main,
                    "update-ref",
                    "-m",
                    OVERRIDES_COMMIT_MSG,
                    "refs/heads/#{branch_name}",
                    commit_id
                )
                @importer.run_git_bare(
                    @main, "push", "-fu", @importer.remote_name, branch_name
                )
                client.branch(buildconf.owner, buildconf.name, branch_name)
            end

            # @param [Github::PullRequest] pull_request
            # @return [Github::Branch]
            def create_branch_for_pr(branch_name, pull_request)
                overrides = overrides_for_pull_request(pull_request)
                created = commit_and_push_overrides(branch_name, overrides)
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
            # @return [Array<Hash>]
            def overrides_for_pull_request(pull_request)
                retriever = OverridesRetriever.new(client)
                all_prs = retriever.retrieve_dependencies(pull_request)
                all_prs << pull_request

                all_prs.flat_map do |pr|
                    packages_affected_by_pull_request(pr).map do |pkg|
                        key = if pkg.package_set?
                                  "pkg_set:#{pkg.vcs[:repository_id]}"
                              else
                                  pkg.package
                              end
                        {
                            key => {
                                "remote_branch" => "refs/pull/#{pr.number}/merge"
                            }
                        }
                    end
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
            # @return [void]
            def trigger_build(branch)
                pr = pull_request_by_branch(branch)
                bb.post_pull_request_changes(pr)
            end

            # @param [Array<Github::Branch>] branches
            # @return [void]
            def trigger_build_if_branch_changed(branches)
                branches.each do |branch|
                    pr = pull_request_by_branch(branch)
                    overrides = overrides_for_pull_request(pr)
                    next unless cache.changed?(pr, overrides)

                    Autoproj.message "Updating "\
                                     "#{pr.base_owner}/#{pr.base_name}##{pr.number}"
                    commit_and_push_overrides(branch.branch_name, overrides)
                    bb.post_pull_request_changes(pr)
                    cache.add(pr, overrides)
                end
            end

            # @return [void]
            def update_cache
                cache.pull_requests.delete_if do |cached_pr|
                    (pull_requests + pull_requests_stale).none? do |tracked_pr|
                        cached_pr.caches_pull_request?(tracked_pr)
                    end
                end
                cache.dump
            end

            # @return [void]
            def poll
                unless updater.update_failed?
                    update_pull_requests
                    update_branches
                    delete_stale_branches
                    created, existing = create_missing_branches

                    created.each { |branch| trigger_build(branch) }
                    trigger_build_if_branch_changed(existing)
                    update_cache
                end

                update_package_branches
                handle_mainline_changes
            end
        end
    end
end
