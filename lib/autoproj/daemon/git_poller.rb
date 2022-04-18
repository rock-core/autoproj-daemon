# frozen_string_literal: true

require "autoproj/daemon/buildbot"
require "autoproj/daemon/pull_request_cache"
require "autoproj/daemon/package_repository"
require "autoproj/daemon/git_api/branch"
require "autoproj/daemon/git_api/client"
require "autoproj/daemon/git_api/pull_request"
require "autoproj/daemon/git_api/url"
require "autoproj/daemon/overrides_retriever"
require "date"
require "yaml"

module Autoproj
    module Daemon
        # This class synchronizes the automatically created branches
        # representing open Pull Requests to the actual Pull Requests
        # on each watched repository
        class GitPoller
            # Delay in {#poll} before we restart the daemon when something went
            # terribly wrong. In seconds.
            EMERGENCY_RESTART_DELAY = 10

            # Delay in {#poll} before we restart the daemon after a failed update
            # In seconds.
            FAILED_UPDATE_RESTART_DELAY = 300

            # @return [Autoproj::Daemon::Buildbot]
            attr_reader :bb

            # @return [Autoproj::Daemon::PackageRepository]
            attr_reader :buildconf

            # @return [GitAPI::Client]
            attr_reader :client

            # @return [PullRequestCache]
            attr_reader :cache

            # @return [Array<Autoproj::Daemon::PackageRepository>]
            attr_reader :packages

            # @return [Array<GitAPI::Branch>]
            attr_reader :branches

            # @return [Array<GitAPI::Branch>]
            attr_reader :package_branches

            # @return [Array<GitAPI::PullRequest>]
            attr_reader :pull_requests

            # @return [Array<GitAPI::PullRequest>]
            attr_reader :pull_requests_stale

            # @return [Autoproj::Workspace]
            attr_reader :ws

            # @return [Autoproj::Daemon::WorkspaceUpdater]
            attr_reader :updater

            # @param [PackageRepository] buildconf Buildconf repository
            # @param [GitAPI::Client] client Git client API
            # @param [Array<Autoproj::Daemon::PackageRepository>] packages An array
            #     with all package repositories to watch
            # @param [Autoproj::Daemon::PullRequestCache] cache Pull request cache
            # @param [Autoproj::Workspace] workspace Current workspace
            # @param [Autoproj::Daemon::WorkspaceUpdater] workspace Current workspace
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
                packages.uniq { |pkg| [GitAPI::URL.new(pkg.repo_url), pkg.branch] }
            end

            # @return [Array<GitAPI::Branch>]
            def update_package_branches
                filtered_repos = unique_packages
                Autoproj.message "Fetching branches from "\
                    "#{filtered_repos.size} repositories..."

                package_branches = filtered_repos.flat_map do |pkg|
                    client.branch(pkg.repo_url, pkg.branch)
                rescue StandardError => e
                    Autoproj.warn "could not fetch information about #{pkg.package} "\
                                  "from #{pkg.repo_url}, branch #{pkg.branch}"
                    Autoproj.warn "ignoring this package until this gets resolved"
                    Autoproj.warn e.message
                    nil
                end

                Autoproj.message "Tracking #{package_branches.size} branches"
                @package_branches = package_branches.compact
            end

            # @param [GitAPI::Branch] branch
            # @return [Array<Autoproj::Daemon::PackageRepository>]
            def packages_by_branch(branch)
                packages.select do |pkg|
                    branch.git_url.same?(pkg.repo_url) && pkg.branch == branch.branch_name
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
                            "Push detected on #{pkg.package}: local: #{pkg.head_sha}, "\
                            "remote: #{branch.sha}"
                        )

                        if updater.update_failed?
                            Autoproj.message "Not triggering build, last update failed"
                            Autoproj.message "The daemon will attempt to update the "\
                                             "workspace, and will trigger a new build "\
                                             "if that's successful"
                        else
                            bb.post_mainline_changes(pkg, branch,
                                                     buildconf_branch: buildconf.branch)
                        end
                        changed = true
                    end
                end

                changed
            end

            # @return [Boolean]
            def trigger_build_if_buildconf_changed
                buildconf_branch = client.branch(buildconf.repo_url, buildconf.branch)
                return false if buildconf.head_sha == buildconf_branch.sha

                Autoproj.message(
                    "Push detected on the buildconf: local: #{buildconf.head_sha}, "\
                    "remote: #{buildconf_branch.sha}"
                )
                bb.post_mainline_changes(buildconf, buildconf_branch,
                                         buildconf_branch: buildconf_branch.branch_name)
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

            # @return [Array<GitAPI::PullRequest>]
            def update_pull_requests
                filtered_repos = unique_packages
                Autoproj.message "Fetching pull requests from "\
                    "#{filtered_repos.size} repositories..."

                @pull_requests = filtered_repos.flat_map do |pkg|
                    client.pull_requests(pkg.repo_url, base: pkg.branch, state: "open")
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

            BuildconfBranch = Struct.new :project, :full_path, :pull_id

            # Parse the buildconf ref into the info it contains
            #
            # The pattern autoproj/PROJECT/FULL_PATH/pulls/ID, matching
            # what {#branch_name_by_pull_request} does.
            #
            # @param [String] branch
            # @return [BuildconfBranch,nil] the info, or nil if the branch
            #    name does not match the expected pattern
            def parse_buildconf_branch(branch_name)
                rx = %r{^autoproj/([A-Za-z0-9_\-.]+)/(.*)/pulls/(\d+)$}
                unless (m = branch_name.match(rx))
                    return
                end
                return if branch_name.split("/").size < 7

                _, project, full_path, number = m.to_a

                pull_id =
                    begin
                        Integer(number)
                    rescue ArgumentError
                        return
                    end

                BuildconfBranch.new(project, full_path, pull_id)
            end

            # @return [Array<GitAPI::Branch>]
            def update_branches
                @branches = client.branches(@buildconf.repo_url)
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
                        pr.git_url.full_path == branch_info.full_path &&
                            pr.number == branch_info.pull_id
                    end
                end
                delete_branches(stale_branches)
            end

            # @param [Array<GitAPI::Branch>] branches
            # @return [void]
            def delete_branches(branches)
                branches.each do |branch|
                    Autoproj.message "Deleting stale branch #{branch.branch_name}"
                    client.delete_branch(branch)
                end
            end

            # @param [GitAPI::PullRequest] pull_request
            # @return [String]
            def self.branch_name_by_pull_request(project, pull_request)
                "autoproj/#{project}/#{pull_request.git_url.full_path}"\
                    "/pulls/#{pull_request.number}"
            end

            # @param [GitAPI::PullRequest] pull_request
            def branch_name_by_pull_request(pull_request)
                self.class.branch_name_by_pull_request(@project, pull_request)
            end

            # @return [(Array<GitAPI::Branch>, Array<GitAPI::Branch>)]
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
                        Autoproj.message "Creating branch #{branch_name}"
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
            # @return [GitAPI::Branch]
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
                client.branch(buildconf.repo_url, branch_name)
            end

            # @param [GitAPI::PullRequest] pull_request
            # @return [GitAPI::Branch]
            def create_branch_for_pr(branch_name, pull_request)
                overrides = overrides_for_pull_request(pull_request)
                created = commit_and_push_overrides(branch_name, overrides)
                cache.add(pull_request, overrides)
                created
            end

            # @param [GitAPI::PullRequest] pull_request
            # @return [Array<PackageRepository>]
            def packages_affected_by_pull_request(pull_request)
                packages.select do |pkg|
                    pull_request.git_url.same?(pkg.repo_url) &&
                        pkg.branch == pull_request.base_branch
                end
            end

            # @param [GitAPI::PullRequest] pull_request
            # @return [Array<Hash>]
            def overrides_for_pull_request(pull_request)
                retriever = OverridesRetriever.new(client)
                all_prs = retriever.retrieve_dependencies(pull_request)
                all_prs << pull_request

                all_prs.flat_map do |pr|
                    packages_affected_by_pull_request(pr).map do |pkg|
                        key = if pkg.package_set?
                                  "pkg_set:#{pkg.overrides_key}"
                              else
                                  pkg.package
                              end
                        {
                            key => {
                                "remote_branch" => client.test_branch_name(pr),
                                "single_branch" => false,
                                "shallow" => false
                            }
                        }
                    end
                end
            end

            # @param [GitAPI::Branch] branch
            # @return [GitAPI::PullRequest, nil]
            def pull_request_by_branch(branch)
                pull_requests.find do |pr|
                    branch_name_by_pull_request(pr) == branch.branch_name
                end
            end

            # @param [GitAPI::Branch] branch
            # @return [void]
            def trigger_build(branch)
                pr = pull_request_by_branch(branch)
                packages = packages_affected_by_pull_request(pr)
                bb.post_pull_request_changes(packages, pr)
            end

            # @param [Array<GitAPI::Branch>] branches
            # @return [void]
            def trigger_build_if_branch_changed(branches)
                branches.each do |branch|
                    pr = pull_request_by_branch(branch)
                    overrides = overrides_for_pull_request(pr)
                    next unless cache.changed?(pr, overrides)

                    Autoproj.message "Updating #{pr.git_url.full_path}##{pr.number}"
                    commit_and_push_overrides(branch.branch_name, overrides)
                    packages = packages_affected_by_pull_request(pr)
                    bb.post_pull_request_changes(packages, pr)
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
                if updater.update_failed?
                    secs = Time.now - updater.update_failed?
                    updater.restart_and_update if secs > FAILED_UPDATE_RESTART_DELAY
                else
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
            rescue StandardError => e
                Autoproj.warn "Exception raised by code in GitPoller#poll"
                Autoproj.warn "Waiting #{EMERGENCY_RESTART_DELAY}s and "\
                              "restarting the daemon"
                Autoproj.warn e.message
                e.backtrace.each do |line|
                    Autoproj.warn "  #{line}"
                end

                sleep EMERGENCY_RESTART_DELAY
                updater.restart_and_update
            end
        end
    end
end
