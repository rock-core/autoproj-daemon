# frozen_string_literal: true

require 'test_helper'
require 'autoproj/daemon/github_watcher'
require 'rubygems/package'
require 'time'

module Autoproj
    # Autoproj's main CLI module
    module CLI
        describe Daemon do # rubocop: disable Metrics/BlockLength
            attr_reader :cli
            attr_reader :ws
            before do
                @ws = ws_create
                @manifest = Autoproj::InstallationManifest.new(
                    ws.installation_manifest_path
                )
                @cli = Daemon.new(@ws)

                flexmock(Autoproj::InstallationManifest)
                    .should_receive(:from_workspace_root).and_return(@manifest)
                flexmock(Autoproj::Daemon::GithubWatcher)
                    .new_instances.should_receive(:watch)
            end

            def define_package(name, vcs)
                pkg = Autoproj::InstallationManifest::Package.new(
                    name, 'Autobuild::CMake', vcs, '/src', '/prefix', '/build', []
                )

                @manifest.add_package(pkg)
            end

            describe '#start' do # rubocop: disable Metrics/BlockLength
                it 'raises if daemon is not properly configured' do
                    assert_raises(Autoproj::ConfigError) do
                        cli.start
                    end
                end

                it 'adds https repositories to github watcher' do
                    define_package('foo', type: 'git',
                                          url: 'https://github.com/owner/foo',
                                          remote_branch: 'develop')

                    flexmock(Autoproj::Daemon::GithubWatcher)
                        .new_instances.should_receive(:add_repository)
                        .with('owner', 'foo', 'develop').once
                    cli.ws.config.daemon_api_key = 'abcdefg'
                    cli.start
                end

                it 'adds ssh repositories to github watcher' do
                    define_package('bar', type: 'git',
                                          url: 'git@github.com:owner/bar',
                                          remote_branch: 'master')

                    flexmock(Autoproj::Daemon::GithubWatcher)
                        .new_instances.should_receive(:add_repository)
                        .with('owner', 'bar', 'master').once
                    cli.ws.config.daemon_api_key = 'abcdefg'
                    cli.start
                end

                it 'does not watch repositories not hosted at github' do
                    define_package('bar', type: 'git',
                                          url: 'git@bitbucket.org.com:owner/bar',
                                          remote_branch: 'develop')

                    flexmock(Autoproj::Daemon::GithubWatcher)
                        .new_instances.should_receive(:add_repository).with(any).never
                    cli.ws.config.daemon_api_key = 'abcdefg'
                    cli.start
                end

                it 'watches main package set if it has a valid vcs definition' do
                    vcs = Autoproj::VCSDefinition.new(
                        'git',
                        'git@github.com:foo/buildconf.git',
                        {}
                    )
                    flexmock(ws.manifest.main_package_set)
                        .should_receive(:vcs).and_return(vcs)
                    flexmock(Autoproj::Daemon::GithubWatcher)
                        .new_instances.should_receive(:add_repository)
                        .with('foo', 'buildconf', 'master').once
                    cli.ws.config.daemon_api_key = 'abcdefg'
                    cli.start
                end
            end

            describe '#configure' do
                it 'configures daemon' do
                    flexmock(ws.config)
                        .should_receive(:configure).with('daemon_api_key').once
                    flexmock(ws.config)
                        .should_receive(:configure).with('daemon_polling_period')
                        .at_least.once
                    cli.configure
                end
            end
        end
    end
end
