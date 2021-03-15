# frozen_string_literal: true

require "test_helper"
require "autoproj/cli/main_daemon"
require "autoproj/cli/daemon"
require "autoproj/daemon/workspace_updater"
require "rubygems/package"
require "time"

module Autoproj
    # Autoproj's main CLI module
    module CLI
        describe MainDaemon do
            before do
                @ws = ws_create
                @ws.save_config
            end
            describe "#start" do
                it "starts the daemon" do
                    flexmock(Autoproj::Daemon::WorkspaceUpdater)
                        .new_instances.should_receive(:update).never

                    flexmock(Daemon).new_instances.should_receive(:start).once
                    flexmock(Daemon).new_instances
                                    .should_receive(:clear_and_dump_cache).never
                    in_ws do
                        MainDaemon.start(%w[start])
                    end
                end

                it "runs an update prior to starting the daemon" do
                    flexmock(Autoproj::Daemon::WorkspaceUpdater)
                        .new_instances.should_receive(:update).once

                    flexmock(Daemon).new_instances.should_receive(:start).once.ordered
                    in_ws do
                        MainDaemon.start(%w[start --update])
                    end
                end
                it "clears the internal cache upon starting the daemon" do
                    flexmock(Daemon).new_instances.should_receive(:clear_and_dump_cache)
                    flexmock(Daemon).new_instances.should_receive(:start).once.ordered
                    in_ws do
                        MainDaemon.start(%w[start --clear-cache])
                    end
                end
            end

            describe "#configure" do
                it "configures the daemon" do
                    flexmock(Daemon).new_instances.should_receive(:configure).once
                    in_ws do
                        MainDaemon.start(%w[configure])
                    end
                end
            end

            describe "#set" do
                it "sets git services parameters" do
                    in_ws do
                        flexmock(Autoproj).should_receive(:workspace).and_return(ws)

                        MainDaemon.start(%w[set github.com abcdef])
                        MainDaemon.start(%w[set gitlab.com foo https://gitlab gitlab])
                        expected_hash = {
                            "github.com" => {
                                "access_token" => "abcdef"
                            },
                            "gitlab.com" => {
                                "service" => "gitlab",
                                "api_endpoint" => "https://gitlab",
                                "access_token" => "foo"
                            }
                        }

                        ws.load_config
                        assert_equal expected_hash, ws.config.daemon_services
                    end
                end
            end

            describe "#unset" do
                it "unsets git services parameters" do
                    in_ws do
                        flexmock(Autoproj).should_receive(:workspace).and_return(ws)

                        MainDaemon.start(%w[set github.com abcdef])
                        MainDaemon.start(%w[set gitlab.com foo https://gitlab gitlab])
                        MainDaemon.start(%w[unset gitlab.com])

                        expected_hash = {
                            "github.com" => {
                                "access_token" => "abcdef"
                            }
                        }

                        ws.load_config
                        assert_equal expected_hash, ws.config.daemon_services
                    end
                end
            end
        end
    end
end
