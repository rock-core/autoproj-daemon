# frozen_string_literal: true

require "autoproj/daemon/github/client"
require "autoproj/daemon/github/branch"
require "autoproj/daemon/buildbot"
require "autoproj/daemon/git_poller"
require "autoproj/daemon/pull_request_cache"
require "autoproj/daemon/workspace_updater"
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
            # @return [Autoproj::Daemon::GitPoller]
            attr_reader :git_poller
            # @return [Autoproj::Daemon::PullRequestCache]
            attr_reader :cache
            # @return [Autoproj::Daemon::Github::Client]
            attr_reader :client
            # @return [Autoproj::Workspace]
            attr_reader :ws
            # @return [String]
            attr_reader :project
            # @return [Autoproj::Daemon::WorkspaceUpdater]
            attr_reader :updater

            def initialize(workspace, updater, load_config: true)
                @ws = workspace
                @ws.load_config if load_config

                @cache = Autoproj::Daemon::PullRequestCache.load(workspace)
                @packages = nil

                manifest_name = @ws.config.get("manifest_name", "manifest")
                subsystem =
                    if (m = /\.(.+)$/.match(manifest_name))
                        m[1]
                    end
                @project = [@ws.config.daemon_project, subsystem].compact.join("_")
                @project = "daemon" if @project.empty?
                @bb = Autoproj::Daemon::Buildbot.new(workspace, project: @project)
                @updater = updater
            end

            # @return [void]
            def clear_and_dump_cache
                @cache.clear
                @cache.dump
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
                @packages
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

                @git_poller = Autoproj::Daemon::GitPoller.new(
                    buildconf_package,
                    client,
                    packages,
                    cache,
                    ws,
                    updater,
                    project: @project
                )
            end

            # Starts polling the whole workspace
            #
            # @return [void]
            def start
                prepare
                loop do
                    git_poller.poll
                    sleep ws.config.daemon_polling_period
                end
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

                ws.config.declare "daemon_project", "string",
                                  default: File.basename(ws.root_dir),
                                  doc: "Enter the project name"

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
                config.configure "daemon_project"
                config.configure "daemon_max_age"
                save_configuration
            end
        end
    end
end
