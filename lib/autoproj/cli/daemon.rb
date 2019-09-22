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
            def initialize(*args)
                super
                initialize_and_load
                ws.config.load
            end

            def resolve_packages
                source_packages, * = finalize_setup(
                    [], non_imported_packages: :return)
                source_packages.map do |pkg_name|
                    ws.manifest.find_package_definition(pkg_name)
                end
            end

            def start
                raise Autoproj::ConfigError, "you must configure the daemon "\
                    "before starting" unless ws.config.daemon_api_key

                packages = resolve_packages
                watcher = GithubWatcher.new(ws)

                packages.each do |pkg|
                    vcs = ws.manifest.importer_definition_for(pkg)

                    next unless vcs.type == 'git'
                    next unless vcs.url =~
                        /(?:(?:https?:\/\/|git@).*)github\.com/i
                    next unless vcs.url =~
                        /(?:[:\/]([A-Za-z\d\-_]+))\/(.+?)(?:\.git$|$)+$/m

                    owner = $1
                    name = $2
                    branch = pkg.autobuild.importer.remote_branch

                    watcher.add_repository(owner, name, branch)
                end
                watcher.watch
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

