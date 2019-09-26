# frozen_string_literal: true

require 'test_helper'
require 'autoproj/cli/main_daemon'
require 'autoproj/cli/daemon'
require 'rubygems/package'
require 'time'

module Autoproj
    # Autoproj's main CLI module
    module CLI
        describe MainDaemon do # rubocop: disable Metrics/BlockLength
            before do
                @ws = ws_create
            end
            describe '#start' do
                it 'starts the daemon' do
                    flexmock(Daemon).new_instances.should_receive(:update).never
                    flexmock(Daemon).new_instances.should_receive(:start).once
                    in_ws do
                        MainDaemon.start(%w[start])
                    end
                end

                it 'runs an update prior to starting the daemon' do
                    flexmock(Daemon).new_instances.should_receive(:update).once
                    flexmock(Daemon).new_instances.should_receive(:start).once.ordered
                    in_ws do
                        MainDaemon.start(%w[start --update])
                    end
                end

                it 'prints error message in case of failure' do
                    flexmock(Autoproj).should_receive(:error).with('foobar').once
                    flexmock(Daemon).new_instances.should_receive(:update).never
                    flexmock(Daemon).new_instances.should_receive(:start).once
                                    .and_return { raise ArgumentError, 'foobar' }
                    in_ws do
                        MainDaemon.start(%w[start])
                    end
                end
            end

            describe '#configure' do
                it 'configures the daemon' do
                    flexmock(Daemon).new_instances.should_receive(:configure).once
                    in_ws do
                        MainDaemon.start(%w[configure])
                    end
                end
            end
        end
    end
end
