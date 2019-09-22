require 'autoproj/cli/inspection_tool'
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
                ws.config.load
            end

            def resolve_packages
                initialize_and_load
                source_packages, * = finalize_setup(
                    [], non_imported_packages: :ignore)
                source_packages.map do |pkg_name|
                    ws.manifest.find_autobuild_package(pkg_name)
                end
            end

            def start
                raise Autoproj::ConfigError, "you must configure the daemon "\
                    "before starting" unless ws.config.daemon_api_key
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

