# frozen_string_literal: true

require "autoproj/cli/update"
require "autoproj/daemon/workspace_updater"
require "test_helper"

module Autoproj
    module Daemon
        describe WorkspaceUpdater do
            include TestHelpers
            attr_reader :updater

            before do
                autoproj_daemon_create_ws(
                    type: "git",
                    url: "git@github.com:rock-core/buildconf"
                )

                @updater = WorkspaceUpdater.new(ws)
            end

            describe "#update" do
                it "triggers an autoproj update" do
                    flexmock(Autoproj::CLI::Update)
                        .new_instances.should_receive(:run)
                        .with([], osdeps: false,
                                  packages: true,
                                  config: true,
                                  deps: true,
                                  reset: :force)
                    assert updater.update
                    refute updater.update_failed?
                end

                it "handles a failed update" do
                    flexmock(Autoproj::CLI::Update)
                        .new_instances.should_receive(:run)
                        .with([], osdeps: false,
                                  packages: true,
                                  config: true,
                                  deps: true,
                                  reset: :force).and_raise(RuntimeError, "foobar")
                    refute updater.update
                    assert updater.update_failed?
                end
                it "prints error message in case of failure" do
                    flexmock(Autoproj).should_receive(:error).with("foobar").once
                    flexmock(Autoproj::CLI::Update)
                        .new_instances.should_receive(:run)
                        .with([], osdeps: false,
                                  packages: true,
                                  config: true,
                                  deps: true,
                                  reset: :force).and_raise(ArgumentError, "foobar")
                    refute updater.update
                    assert updater.update_failed?
                end
            end
        end
    end
end
