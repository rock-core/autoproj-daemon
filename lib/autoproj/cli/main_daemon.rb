require 'autoproj'
require 'thor'
require 'autoproj/cli/daemon'

module Autoproj
    module CLI
        # CLI interface for autoproj-daemon
        class MainDaemon < Thor
            desc 'start [ARGS]', 'Starts autoproj daemon plugin'
            option :update, type: 'boolean',
                desc: 'do an update operation before starting'
            def start(*args)
                require 'autoproj/cli/daemon'
                daemon = Daemon.new

                daemon.start
            rescue StandardError => e
                Autoproj.error e.message
            end

            desc 'configure', "Configures autoproj daemon plugin"
            def configure(*args)
                daemon = Daemon.new
                daemon.configure
            end
        end
    end
end
