require 'test_helper'
require 'autoproj/github_watcher'
require 'rubygems/package'
require 'time'

module Autoproj::CLI
    describe Daemon do
        attr_reader :cli
        attr_reader :ws
        before do
            @ws = ws_create
            Timecop.freeze(Time.parse("2019-09-22 23:48:00 UTC"))
            mock_github_client
            @cli = Daemon.new(@ws)
            flexmock(Autoproj::GithubWatcher).new_instances
                .should_receive(:watch)
        end

        def define_package(name, vcs)
            pkg = ws_define_package :cmake, name
            pkg.autobuild.importer = flexmock(interactive?: false)
            flexmock(pkg.autobuild.importer).should_receive(:import)
            flexmock(pkg.autobuild.importer).should_receive(:remote_branch)
                .and_return(vcs[:remote_branch])
            ws_define_package_vcs(pkg, vcs)
        end

        describe '#start' do
            it 'raises if daemon is not properly configured' do
                assert_raises(Autoproj::ConfigError) do
                    cli.start
                end
            end

            it 'adds https repositories to github watcher' do
                define_package('foo',
                    type: 'git',
                    url: 'https://github.com/owner/foo',
                    remote_branch: 'develop')

                flexmock(Autoproj::GithubWatcher).new_instances
                    .should_receive(:add_repository)
                    .with('owner', 'foo', 'develop').once
                cli.ws.config.daemon_api_key = 'abcdefg'
                cli.start
            end

            it 'adds ssh repositories to github watcher' do
                define_package('bar',
                    type: 'git',
                    url: 'git@github.com:owner/bar',
                    remote_branch: 'master')

                flexmock(Autoproj::GithubWatcher).new_instances
                    .should_receive(:add_repository)
                    .with('owner', 'bar', 'master').once
                cli.ws.config.daemon_api_key = 'abcdefg'
                cli.start
            end

            it 'does not watch repositories not hosted at github' do
                define_package('bar',
                    type: 'git',
                    url: 'git@bitbucket.org.com:owner/bar',
                    remote_branch: 'develop')

                flexmock(Autoproj::GithubWatcher).new_instances
                    .should_receive(:add_repository).with(any).never
                cli.ws.config.daemon_api_key = 'abcdefg'
                cli.start
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
