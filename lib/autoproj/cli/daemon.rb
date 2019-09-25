require 'autoproj/cli/inspection_tool'
require 'autoproj/github_watcher'
require 'tmpdir'

module Autoproj
    module CLI
        # Actual implementation of the functionality for the `autoproj daemon` subcommand
        #
        # Autoproj internally splits the CLI definition (Thor subclass) and the
        # underlying functionality of each CLI subcommand. `autoproj-daemon` follows the
        # same pattern, and registers its subcommand in {MainDaemon} while implementing
        # the functionality in this class
        class Daemon < InspectionTool
            attr_reader :watcher
            def initialize(*args)
                super
                ws.config.load
                @update_failed = false
            end

            # Loads all package definitions from the installation manifest
            #
            # @return [Array<Autoproj::InstallationManifest::Package,
            #     Autoproj::InstallationManifest::PackageSet>] package array
            def resolve_packages
                installation_manifest = Autoproj::InstallationManifest
                    .from_workspace_root(ws.root_dir)
                installation_manifest.each_package.to_a +
                    installation_manifest.each_package_set.to_a
            end

            # Adds a VCS definition to the watch list of the internal
            # GithubWatcher instance
            #
            # @param [Hash] vcs Hash representation of an Autoproj::VCSDefinition
            # @return [Boolean] whether the given hash was valid or not
            def watch_vcs_definition(vcs)
                return false unless vcs[:type] == 'git'
                return false unless vcs[:url] =~
                    /(?:(?:https?:\/\/|git@).*)github\.com/i
                return false unless vcs[:url] =~
                    /(?:[:\/]([A-Za-z\d\-_]+))\/(.+?)(?:\.git$|$)+$/m

                owner = $1
                name = $2
                branch = vcs[:remote_branch] ||
                    vcs[:branch] || 'master'

                watcher.add_repository(owner, name, branch)
                true
            end

            # Starts watching the whole workspace
            #
            # @return [nil]
            def start
                raise Autoproj::ConfigError, "you must configure the daemon "\
                    "before starting" unless ws.config.daemon_api_key

                packages = resolve_packages
                @watcher = GithubWatcher.new(ws)

                packages.each do |pkg|
                    watch_vcs_definition(pkg.vcs)
                end
                watch_vcs_definition(ws.manifest.main_package_set.vcs.to_hash)

                watcher.add_push_hook do |repo, options|
                    exec($PROGRAM_NAME, 'daemon', 'start', '--update')
                end
                watcher.watch
                nil
            end

            # Updates the current workspace. This method will invoke the CLI
            # (same as doing an 'autoproj update --no-interactive --no-osdeps').
            # The member variable @update_failed will store the result of the
            # update attempt.
            #
            # @return [Boolean] whether the update failed or not
            def update
                Main.start(
                    ['update', '--no-osdeps', '--no-interactive', ws.root_dir])
                @update_failed = false
                true
            rescue StandardError
                @update_failed = true
                false
            end

            # (Re)configures the daemon
            #
            # @return [nil]
            def configure
                ws.config.declare 'daemon_api_key', 'string',
                    doc: 'Enter a github API key for authentication'

                ws.config.declare 'daemon_polling_period', 'string',
                    default: '60',
                    doc: 'Enter the github polling period'

                ws.config.configure 'daemon_api_key'
                ws.config.configure 'daemon_polling_period'

                ws.config.daemon_polling_period = ws.config.daemon_polling_period.to_i
                ws.config.save
                nil
            end
        end
    end
end

