# frozen_string_literal: true

require "autoproj"
require "thor"
require "autoproj/cli/daemon"
require "autoproj/daemon/workspace_updater"
require "faraday-http-cache"

module Autoproj
    module CLI
        # CLI interface for autoproj-daemon
        class MainDaemon < Thor
            desc "start [OPTIONS]", "Starts autoproj daemon plugin"
            option :clear_cache, type: "boolean",
                                 desc: "clear internal PR cache "\
                                       "(rebuilds all tracked PRs)"
            option :update, type: "boolean",
                            desc: "do an update operation before starting"
            def start(*_args)
                stack = Faraday::RackBuilder.new do |builder|
                    builder.use Faraday::HttpCache, serializer: Marshal,
                                                    shared_cache: false

                    builder.use Octokit::Middleware::FollowRedirects
                    builder.use Octokit::Response::RaiseError
                    builder.adapter Faraday.default_adapter
                end
                Octokit.middleware = stack

                ws = Autoproj.workspace
                updater = Autoproj::Daemon::WorkspaceUpdater.new(ws)

                daemon = Daemon.new(ws, updater)
                daemon.clear_and_dump_cache if options[:clear_cache]
                updater.update if options[:update]
                daemon.start
            end

            desc "configure", "Configures autoproj daemon plugin"
            def configure(*_args)
                ws = Autoproj.workspace
                updater = Autoproj::Daemon::WorkspaceUpdater.new(ws)

                daemon = Daemon.new(ws, updater)
                daemon.configure
            end
        end
    end
end
