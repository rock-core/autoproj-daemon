# frozen_string_literal: true

require "test_helper"
require "autoproj/cli/main_daemon"
require "autoproj/cli/daemon"
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
                    flexmock(Daemon).new_instances.should_receive(:update).never
                    flexmock(Daemon).new_instances.should_receive(:start).once
                    flexmock(Daemon).new_instances
                                    .should_receive(:clear_and_dump_cache).never
                    in_ws do
                        MainDaemon.start(%w[start])
                    end
                end

                it "runs an update prior to starting the daemon" do
                    flexmock(Daemon).new_instances.should_receive(:update).once
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
        end
    end
end
