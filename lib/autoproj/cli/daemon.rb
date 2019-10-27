# frozen_string_literal: true

require 'autoproj/cli/inspection_tool'
require 'autoproj/daemon/github/client'
require 'autoproj/daemon/github/branch'
require 'autoproj/daemon/buildbot'
require 'autoproj/daemon/buildconf_manager'
require 'autoproj/daemon/pull_request_cache'
require 'autoproj/daemon/github_watcher'
require 'octokit'

module Autoproj
    module CLI
        # Actual implementation of the functionality for the `autoproj daemon` subcommand
        #
        # Autoproj internally splits the CLI definition (Thor subclass) and the
        # underlying functionality of each CLI subcommand. `autoproj-daemon` follows the
        # same pattern, and registers its subcommand in {MainDaemon} while implementing
        # the functionality in this class
        class Daemon
            attr_reader :bb
            attr_reader :buildconf_manager
            attr_reader :cache
            attr_reader :client
            attr_reader :watcher
            attr_reader :ws

            def initialize(workspace)
                @bb = Autoproj::Daemon::Buildbot.new(workspace)
                @cache = Autoproj::Daemon::PullRequestCache.load(workspace)
                @ws = workspace
                ws.config.load if File.exist?(ws.config_file_path)
                @update_failed = false
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
            def parse_repo_url_from_vcs(vcs)
                return unless vcs[:type] == 'git'
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

            # Whether an attempt to update the workspace has failed
            #
            # @param [Autoproj::Daemon::Github::PullRequest] pull_request
            # @return [Boolean]
            def buildconf_pull_request?(pull_request)
                pull_request.base_owner == buildconf_package.owner &&
                    pull_request.base_name == buildconf_package.name
            end

            # @param [Github::PushEvent] push_event
            # @return [void]
            def handle_mainline_push(push_event)
                Autoproj.message "Push detected on #{push_event.owner}/"\
                    "#{push_event.name}, branch: #{push_event.branch}"

                bb.build unless update_failed?
                restart_and_update
            end

            # @param [Github::PullRequest] pull_request
            # @return [void]
            def handle_pull_request_push(pull_request)
                overrides = buildconf_manager.overrides_for_pull_request(pull_request)
                return unless cache.changed?(pull_request, overrides)

                branch_name =
                    Autoproj::Daemon::BuildconfManager.branch_name_by_pull_request(
                        pull_request
                    )

                buildconf_manager.commit_and_push_overrides(branch_name, overrides)
                cache.add(pull_request, overrides)

                Autoproj.message "Push detected on #{pull_request.base_owner}/"\
                    "#{pull_request.base_name}##{pull_request.number}"

                bb.build(branch: branch_name)
                cache.dump
            end

            # @param [Github::PushEvent] push_event
            # @return [void]
            def handle_push_event(push_event, mainline: nil, pull_request: nil)
                return handle_mainline_push(push_event) if mainline
                return if update_failed? || buildconf_pull_request?(pull_request)

                handle_pull_request_push(pull_request)
            end

            # @param [Github::PullRequest] pull_request
            # @return [void]
            def handle_pull_request_opened(pull_request)
                branch_name =
                    Autoproj::Daemon::BuildconfManager.branch_name_by_pull_request(
                        pull_request
                    )

                overrides = buildconf_manager.overrides_for_pull_request(pull_request)
                return unless cache.changed?(pull_request, overrides)

                Autoproj.message "Creating branch #{branch_name} "\
                    "on #{buildconf_package.owner}/#{buildconf_package.name}"

                buildconf_manager.commit_and_push_overrides(branch_name, overrides)
                bb.build(branch: branch_name)

                cache.add(pull_request, overrides)
                cache.dump
            end

            # @param [Github::PullRequest] pull_request
            # @return [void]
            def handle_pull_request_closed(pull_request)
                branch_name =
                    Autoproj::Daemon::BuildconfManager.branch_name_by_pull_request(
                        pull_request
                    )
                begin
                    Autoproj.message "Deleting stale branch #{branch_name} "\
                        "from #{buildconf_package.owner}/#{buildconf_package.name}"

                    client.delete_branch_by_name(buildconf_package.owner,
                                                 buildconf_package.name, branch_name)
                    cache.delete(pull_request)

                # rubocop: disable Lint/HandleExceptions
                rescue Octokit::UnprocessableEntity
                end
                # rubocop: enable Lint/HandleExceptions

                cache.dump
            end

            # @param [Github::PullRequestEvent] pull_request_event
            # @return [void]
            def handle_pull_request_event(pull_request_event)
                return if update_failed?
                return if buildconf_pull_request?(pull_request_event.pull_request)

                pr = pull_request_event.pull_request
                return handle_pull_request_opened(pr) if pr.open?

                handle_pull_request_closed(pr)
            end

            # @return [void]
            def restart_and_update
                Process.exec(
                    Gem.ruby, $PROGRAM_NAME, 'daemon', 'start', '--update'
                )
            end

            # Adds hooks for Github events
            #
            # @return [void]
            def setup_hooks
                watcher.add_push_hook do |push_event, **options|
                    handle_push_event(push_event, options)
                end
                watcher.add_pull_request_hook do |pull_request_event|
                    handle_pull_request_event(pull_request_event)
                end
            end

            # @return [Array<PackageRepository>]
            def packages
                return @packages if @packages

                @packages = resolve_packages.map do |pkg|
                    vcs = pkg[:vcs]
                    next unless (match = parse_repo_url_from_vcs(vcs))

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
            end

            # @return [PackageRepository]
            def buildconf_package
                return @buildconf_package if @buildconf_package

                ws.load_config
                vcs = ws.manifest.main_package_set.vcs.to_hash
                unless (match = parse_repo_url_from_vcs(vcs))
                    raise Autoproj::ConfigError,
                          'Main configuration not managed by github'
                end

                owner, name = match
                @buildconf_package = Autoproj::Daemon::PackageRepository.new(
                    'main configuration',
                    owner,
                    name,
                    vcs,
                    buildconf: true,
                    local_dir: ws.config_dir,
                    ws: ws
                )
            end

            # Starts watching the whole workspace
            #
            # @return [void]
            def start
                unless ws.config.daemon_api_key
                    raise Autoproj::ConfigError, 'you must configure the '\
                        'daemon before starting'
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
                    ws
                )
                @watcher = Autoproj::Daemon::GithubWatcher.new(
                    client,
                    packages + [buildconf_package],
                    cache,
                    ws
                )

                setup_hooks
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
                Main.default_report_on_package_failures = :raise
                Main.start(
                    ['update', '--no-osdeps', '--no-interactive',
                     '--force-reset', ws.root_dir]
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
                ws.config.declare 'daemon_api_key', 'string',
                                  doc: 'Enter a github API key for authentication'

                ws.config.declare 'daemon_polling_period', 'string',
                                  default: '60',
                                  doc: 'Enter the github polling period'

                ws.config.declare 'daemon_buildbot_host', 'string',
                                  default: 'localhost',
                                  doc: 'Enter builbot host/ip'

                ws.config.declare 'daemon_buildbot_port', 'string',
                                  default: '8010',
                                  doc: 'Enter buildbot http port'

                ws.config.declare 'daemon_buildbot_scheduler', 'string',
                                  default: 'build-force',
                                  doc: 'Enter builbot scheduler name'
            end

            # Saves daemon configurations
            #
            # @return [void]
            def save_configuration
                ws.config.daemon_polling_period =
                    ws.config.daemon_polling_period.to_i
                ws.config.save
            end

            # (Re)configures the daemon
            #
            # @return [void]
            def configure
                declare_configuration_options
                config = ws.config
                config.configure 'daemon_api_key'
                config.configure 'daemon_polling_period'
                config.configure 'daemon_buildbot_host'
                config.configure 'daemon_buildbot_port'
                config.configure 'daemon_buildbot_scheduler'
                save_configuration
            end
        end
    end
end
