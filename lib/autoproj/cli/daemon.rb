# frozen_string_literal: true

require "autoproj/cli/update"
require "autoproj/daemon/github/client"
require "autoproj/daemon/github/branch"
require "autoproj/daemon/buildbot"
require "autoproj/daemon/buildconf_manager"
require "autoproj/daemon/pull_request_cache"
require "autoproj/daemon/github_watcher"
require "octokit"

module Autoproj
    module CLI
        # Actual implementation of the functionality for the `autoproj daemon` subcommand
        #
        # Autoproj internally splits the CLI definition (Thor subclass) and the
        # underlying functionality of each CLI subcommand. `autoproj-daemon` follows the
        # same pattern, and registers its subcommand in {MainDaemon} while implementing
        # the functionality in this class
        class Daemon
            # @return [Autoproj::Daemon::Buildbot]
            attr_reader :bb
            # @return [Autoproj::Daemon::BuildconfManager]
            attr_reader :buildconf_manager
            # @return [Autoproj::Daemon::PullRequestCache]
            attr_reader :cache
            # @return [Autoproj::Daemon::Github::Client]
            attr_reader :client
            # @return [Autoproj::Daemon::GithubWatcher]
            attr_reader :watcher
            # @return [Autoproj::Workspace]
            attr_reader :ws
            # @return [String]
            attr_reader :project

            def initialize(workspace, load_config: true)
                @ws = workspace
                @ws.load_config if load_config

                @cache = Autoproj::Daemon::PullRequestCache.load(workspace)
                @packages = nil
                @update_failed = false

                manifest_name = @ws.config.get("manifest_name", "manifest")
                subsystem =
                    if (m = /\.(.+)$/.match(manifest_name))
                        m[1]
                    end
                @project = [@ws.config.daemon_project, subsystem].compact.join("_")
                @project = "daemon" if @project.empty?
                @bb = Autoproj::Daemon::Buildbot.new(workspace, project: @project)
            end

            # Loads all package definitions from the installation manifest
            #
            # @return [Array<Autoproj::InstallationManifest::Package,
            #     Autoproj::InstallationManifest::PackageSet>] package array
            def resolve_packages
                installation_manifest =
                    Autoproj::InstallationManifest.from_workspace_root(ws.root_dir)
                installation_manifest.each_package.to_a +
                    installation_manifest.each_package_set.to_a
            end

            VALID_URL_RX = /github.com/i.freeze
            PARSE_URL_RX = %r{(?:[:/]([A-Za-z\d\-_]+))/(.+?)(?:.git$|$)+$}m.freeze

            # Parses a repository url
            #
            # @param [Hash] vcs The package vcs hash
            # @return [Array<String>, nil] An array with the owner and repo name
            def self.parse_repo_url_from_vcs(vcs)
                return unless vcs[:type] == "git"
                return unless vcs[:url] =~ VALID_URL_RX
                return unless (match = PARSE_URL_RX.match(vcs[:url]))

                [match[1], match[2]]
            end

            # Whether an attempt to update the workspace has failed
            #
            # @return [Boolean]
            def update_failed?
                @update_failed
            end

            # Whether the given PR targets the buildconf
            #
            # @param [Autoproj::Daemon::Github::PullRequest] pull_request
            # @return [Boolean]
            def buildconf_pull_request?(pull_request)
                pull_request.base_owner == buildconf_package.owner &&
                    pull_request.base_name == buildconf_package.name
            end

            # Whether the given push event belongs to the buildconf
            #
            # @param [Autoproj::Daemon::Github::PushEvent] push_event
            # @return [Boolean]
            def buildconf_push?(push_event)
                push_event.owner == buildconf_package.owner &&
                    push_event.name == buildconf_package.name
            end

            # @return [void]
            def clear_and_dump_cache
                @cache.clear
                @cache.dump
            end

            # Process modifications
            #
            # @param [{PackageRepository=>[Autoproj::GitHub::PushEvent]}]
            #        modified_mainlines
            # @param [{Autoproj::Github::PullRequest=>
            #          [Autoproj::Github::PullRequestEvent,Autoproj::Github::PushEvent]}]
            #          modified_pull_requests
            # @return [void]
            def handle_modifications(modified_mainlines, modified_pull_requests)
                unless modified_mainlines.empty?
                    handle_mainline_modifications(modified_mainlines)
                end

                modified_pull_requests.each_key do |pull_request|
                    next if buildconf_pull_request?(pull_request)

                    handle_pull_request_modifications(pull_request)
                end
            end

            # @api private
            #
            # Process events that concern a package's mainline branch
            #
            # @param [{PackageRepository=>[GitHub::PushEvent]}] modified_mainlines
            # @return [void]
            def handle_mainline_modifications(modified_mainlines)
                modified_mainlines.each do |pkg, events|
                    Autoproj.message(
                        "Push detected on #{pkg.name}, current: #{pkg.head_sha}"
                    )
                    events.each do |ev|
                        Autoproj.message(
                            "  #{ev.owner}/#{ev.name}, branch: #{ev.branch} "\
                            "#{ev.head_sha}"
                        )
                    end
                end

                if update_failed?
                    Autoproj.message "Not triggering build, the last update failed"
                    Autoproj.message "The daemon will attempt to update the workspace, "\
                                     "and will trigger a new build if that's successful"
                else
                    modified_mainlines.each do |package, events|
                        bb.post_mainline_changes(package, events)
                    end
                end

                buildconf_push = modified_mainlines.each_value.any? do |events|
                    events.any? { |ev| buildconf_push?(ev) }
                end
                clear_and_dump_cache if buildconf_push
                restart_and_update
            end

            # @api private
            #
            # Process events that concern a pull request
            #
            # @param [Daemon::Github::PullRequest] pull_request
            # @return [void]
            def handle_pull_request_modifications(pull_request)
                # Check whether the pull request closed, and if we're aware
                unless pull_request.open?
                    if cache.include?(pull_request)
                        handle_pull_request_closed(pull_request)
                    end
                    return
                end

                unless cache.include?(pull_request)
                    return handle_pull_request_opened(pull_request)
                end

                handle_pull_request_changes(pull_request)
            end

            # @api private
            #
            # Handle a pull request whose source SHA has changed
            #
            # @param [Daemon::Github::PullRequest] pull_request
            # @return [void]
            def handle_pull_request_changes(pull_request)
                overrides = buildconf_manager.overrides_for_pull_request(pull_request)
                return unless cache.changed?(pull_request, overrides)

                branch_name = branch_name_by_pull_request(pull_request)
                buildconf_manager.commit_and_push_overrides(branch_name, overrides)
                cache.add(pull_request, overrides)

                Autoproj.message "Push detected on #{pull_request.base_owner}/"\
                    "#{pull_request.base_name}##{pull_request.number}"

                bb.post_pull_request_changes(pull_request)
                cache.dump
            end

            # @api private
            #
            # Handle a pull request that has just been opened
            #
            # @param [Autoproj::Daemon::Github::PullRequest] pull_request
            # @return [void]
            def handle_pull_request_opened(pull_request)
                branch_name = branch_name_by_pull_request(pull_request)
                overrides = buildconf_manager.overrides_for_pull_request(pull_request)

                Autoproj.message "Creating branch #{branch_name} "\
                    "on #{buildconf_package.owner}/#{buildconf_package.name}"

                buildconf_manager.commit_and_push_overrides(branch_name, overrides)
                bb.post_pull_request_changes(pull_request)

                cache.add(pull_request, overrides)
                cache.dump
            end

            # @api private
            #
            # Handle a pull request that has just been closed
            #
            # @param [Autoproj::Daemon::Github::PullRequest] pull_request
            # @return [void]
            def handle_pull_request_closed(pull_request)
                branch_name = branch_name_by_pull_request(pull_request)
                begin
                    Autoproj.message "Deleting stale branch #{branch_name} "\
                        "from #{buildconf_package.owner}/#{buildconf_package.name}"

                    client.delete_branch_by_name(buildconf_package.owner,
                                                 buildconf_package.name, branch_name)
                    cache.delete(pull_request)
                rescue Octokit::UnprocessableEntity # rubocop:disable Lint/SuppressedException
                end

                cache.dump
            end

            # @return [void]
            def restart_and_update
                Process.exec(
                    Gem.ruby, $PROGRAM_NAME, "daemon", "start", "--update"
                )
            end

            # Subscribe to GitHub events using {#watcher}
            #
            # @return [void]
            def setup_hooks
                watcher.subscribe do |packages, pull_requests|
                    handle_modifications(packages, pull_requests)
                end
            end

            # Return the list of packages in the current state of the workspace
            #
            # This list is computed only once, and then memoized
            #
            # @return [Array<PackageRepository>]
            def packages
                return @packages if @packages

                @packages = resolve_packages.map do |pkg|
                    vcs = pkg[:vcs]
                    unless (match = self.class.parse_repo_url_from_vcs(vcs))
                        Autoproj.message "ignored #{pkg.name}: VCS not matching"
                        next
                    end
                    next if vcs[:commit] || vcs[:tag]

                    owner, name = match
                    package_set = pkg.kind_of? Autoproj::InstallationManifest::PackageSet

                    pkg = pkg.to_h
                    local_dir = if package_set
                                    pkg[:raw_local_dir]
                                else
                                    pkg[:importdir] || pkg[:srcdir]
                                end

                    Autoproj::Daemon::PackageRepository.new(
                        pkg[:name] || pkg[:package_set],
                        owner,
                        name,
                        vcs,
                        package_set: package_set,
                        local_dir: local_dir,
                        ws: ws
                    )
                end.compact
                @packages << buildconf_package
            end

            # The package object that represents the buildconf
            #
            # @return [Autoproj::Daemon::PackageRepository]
            def buildconf_package
                return @buildconf_package if @buildconf_package

                @buildconf_package ||= self.class.buildconf_package(ws)
            end

            # Create a package object to represent a workspace's buildocnf
            #
            # @return [Autoproj::Daemon::PackageRepository]
            def self.buildconf_package(ws)
                vcs = ws.manifest.main_package_set.vcs.to_hash
                unless (match = parse_repo_url_from_vcs(vcs))
                    raise Autoproj::ConfigError,
                          "Main configuration not managed by github"
                end

                owner, name = match
                @buildconf_package = Autoproj::Daemon::PackageRepository.new(
                    "main configuration",
                    owner,
                    name,
                    vcs,
                    buildconf: true,
                    local_dir: ws.config_dir,
                    ws: ws
                )
            end

            # @return [void]
            def prepare
                unless ws.config.daemon_api_key
                    raise Autoproj::ConfigError,
                          "required configuration daemon_api_key not set"
                end
                @client = Autoproj::Daemon::Github::Client.new(
                    access_token: ws.config.daemon_api_key,
                    auto_paginate: true
                )

                @buildconf_manager = Autoproj::Daemon::BuildconfManager.new(
                    buildconf_package,
                    client,
                    packages,
                    cache,
                    ws,
                    project: @project
                )
                @watcher = Autoproj::Daemon::GithubWatcher.new(
                    client,
                    packages + [buildconf_package],
                    cache,
                    ws
                )

                setup_hooks
            end

            # Starts watching the whole workspace
            #
            # @return [void]
            def start
                prepare
                buildconf_manager.synchronize_branches unless update_failed?
                watcher.watch
            end

            # Updates the current workspace. This method will invoke the CLI
            # (same as doing an 'autoproj update --no-interactive --no-osdeps').
            # The member variable @update_failed will store the result of the
            # update attempt.
            #
            # @return [Boolean] whether the update failed or not
            def update
                ws.config.interactive = false
                Update.new(ws).run(
                    [], reset: :force,
                        packages: true,
                        config: true,
                        deps: true,
                        osdeps: false
                )
                @update_failed = false
                true
            rescue StandardError => e
                # if this is true, the only thing the daemon
                # should do is update the workspace on push events,
                # no PR syncing and no triggering of builds
                # on PR events
                @update_failed = true
                Autoproj.error e.message
                false
            end

            # Declares daemon configuration options
            #
            # @return [void]
            def declare_configuration_options
                ws.config.declare "daemon_api_key", "string",
                                  doc: "Enter a github API key for authentication"

                ws.config.declare "daemon_polling_period", "string",
                                  default: "60",
                                  doc: "Enter the github polling period"

                ws.config.declare "daemon_buildbot_host", "string",
                                  default: "localhost",
                                  doc: "Enter builbot host/ip"

                ws.config.declare "daemon_buildbot_port", "string",
                                  default: "8010",
                                  doc: "Enter buildbot http port"

                ws.config.declare "daemon_buildbot_scheduler", "string",
                                  default: "build-force",
                                  doc: "Enter builbot scheduler name"

                ws.config.declare "daemon_max_age", "string",
                                  default: "120",
                                  doc: "Enter events and pull requests max age"
            end

            # Saves daemon configurations
            #
            # @return [void]
            def save_configuration
                ws.config.daemon_polling_period =
                    ws.config.daemon_polling_period.to_i
                ws.config.daemon_max_age =
                    ws.config.daemon_max_age.to_i
                ws.config.save
            end

            # (Re)configures the daemon
            #
            # @return [void]
            def configure
                declare_configuration_options
                config = ws.config
                config.configure "daemon_api_key"
                config.configure "daemon_polling_period"
                config.configure "daemon_buildbot_host"
                config.configure "daemon_buildbot_port"
                config.configure "daemon_buildbot_scheduler"
                config.configure "daemon_max_age"
                save_configuration
            end

            # Returns the buildconf branch that should be used to configure a build
            # for a given pull request
            #
            # @param [Autoproj::Daemon::Github::PullRequest] pull_request
            # @return [String]
            def branch_name_by_pull_request(pull_request)
                Autoproj::Daemon::BuildconfManager.branch_name_by_pull_request(
                    @project, pull_request
                )
            end
        end
    end
end
