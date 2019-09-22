require "test_helper"
require 'rubygems/package'

module Autoproj::CLI
    describe Daemon do
        attr_reader :cli
        attr_reader :ws
        before do
            @ws = ws_create
            @archive_dir = make_tmpdir
            @prefix_dir = make_tmpdir

            @pkg = ws_define_package :cmake, 'foo'
            @cli = Daemon.new(@ws)
        end

        describe '#start' do
            it 'raises if daemon is not properly configured' do
                assert_raises(Autoproj::ConfigError) do
                    cli.start
                end
            end
        end

        describe '#configure' do
            it 'configures daemon' do
                flexmock(ws.config).should_receive(:configure)
                    .with('daemon_api_key').once
                flexmock(ws.config).should_receive(:configure)
                    .with('daemon_polling_period').at_least.once
                cli.configure
            end
        end
    end
end
