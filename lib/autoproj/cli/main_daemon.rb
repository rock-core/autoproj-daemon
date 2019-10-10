# frozen_string_literal: true

require 'autoproj'
require 'thor'
require 'autoproj/cli/daemon'

module Autoproj
    module CLI
        # CLI interface for autoproj-daemon
        class MainDaemon < Thor
            desc 'start [OPTIONS]', 'Starts autoproj daemon plugin'
            option :update, type: 'boolean',
                            desc: 'do an update operation before starting'
            def start(*_args)
                daemon = Daemon.new(Autoproj.workspace)
                daemon.update if options[:update]
                daemon.start
            end

            desc 'configure', 'Configures autoproj daemon plugin'
            def configure(*_args)
                daemon = Daemon.new(Autoproj.workspace)
                daemon.configure
            end
        end
    end
end
