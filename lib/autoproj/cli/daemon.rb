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

            def resolve_packages
                installation_manifest = Autoproj::InstallationManifest
                    .from_workspace_root(ws.root_dir)
                installation_manifest.each_package.to_a +
                    installation_manifest.each_package_set.to_a
            end

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
            end

            def update
                Main.start(
                    ['update', '--no-osdeps', '--no-interactive', ws.root_dir])
            rescue StandardError
                @update_failed = true
            end

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
            end
        end
    end
end

