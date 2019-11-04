# frozen_string_literal: true

require 'autoproj'
require 'thor'
require 'autoproj/cli/daemon'
require 'faraday-http-cache'

module Autoproj
    module CLI
        # CLI interface for autoproj-daemon
        class MainDaemon < Thor
            desc 'start [OPTIONS]', 'Starts autoproj daemon plugin'
            option :update, type: 'boolean',
                            desc: 'do an update operation before starting'
            def start(*_args)
                stack = Faraday::RackBuilder.new do |builder|
                    builder.use Faraday::HttpCache, serializer: Marshal,
                                                    shared_cache: false

                    builder.use Octokit::Response::RaiseError
                    builder.adapter Faraday.default_adapter
                end
                Octokit.middleware = stack

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
