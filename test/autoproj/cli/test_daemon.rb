# frozen_string_literal: true

require 'test_helper'
require 'autoproj/cli/main'
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

            describe '#parse_repo_url' do # rubocop: disable Metrics/BlockLength
                it 'parses an http url' do
                    owner, name = cli.parse_repo_url(
                        'http://github.com/rock-core/autoproj'
                    )
                    assert_equal 'rock-core', owner
                    assert_equal 'autoproj', name
                end

                it 'parses a ssh url' do
                    owner, name = cli.parse_repo_url(
                        'git@github.com:rock-core/autoproj'
                    )
                    assert_equal 'rock-core', owner
                    assert_equal 'autoproj', name
                end

                it 'removes git extension from repo name' do
                    owner, name = cli.parse_repo_url(
                        'git@github.com:rock-core/autoproj.git'
                    )
                    assert_equal 'rock-core', owner
                    assert_equal 'autoproj', name
                end

                it 'returns nil for incomplete urls' do
                    assert_nil cli.parse_repo_url(
                        'git@github.com:rock-core/'
                    )
                end
            end

            describe 'VALID_URL_RX' do
                it 'allows only github urls' do
                    assert_nil Daemon::VALID_URL_RX.match(
                        'git@bitbucket.org:rock-core/autoproj'
                    )
                    assert_nil Daemon::VALID_URL_RX.match(
                        'http://bitbucket.org:rock-core/autoproj'
                    )
                    assert Daemon::VALID_URL_RX.match(
                        'git@github.com:rock-core/autoproj'
                    )
                    assert Daemon::VALID_URL_RX.match(
                        'ssh://github.com:rock-core/autoproj'
                    )
                    assert Daemon::VALID_URL_RX.match(
                        'http://github.com:rock-core/autoproj'
                    )
                end
            end

            describe '#setup_hooks' do
                it 'updates the workspace on push event' do
                    watcher = flexmock
                    flexmock(cli).should_receive(:watcher).and_return(watcher)
                    flexmock(Process)
                        .should_receive(:exec)
                        .with(Gem.ruby, $PROGRAM_NAME, 'daemon',
                              'start', '--update').once

                    watcher.should_receive(:add_push_hook)
                           .and_yield('rock-core', 'autoproj')
                    cli.setup_hooks
                end
            end

            describe '#update' do # rubocop: disable Metrics/BlockLength
                it 'triggers an autoproj update' do
                    flexmock(Main).should_receive(:start)
                                  .with(['update',
                                         '--no-osdeps',
                                         '--no-interactive',
                                         ws.root_dir]).and_return(true)
                    assert cli.update
                    refute cli.update_failed?
                end

                it 'handles a failed update' do
                    flexmock(Main).should_receive(:start)
                                  .with(['update',
                                         '--no-osdeps',
                                         '--no-interactive',
                                         ws.root_dir]).and_return { raise }
                    refute cli.update
                    assert cli.update_failed?
                end
                it 'prints error message in case of failure' do
                    flexmock(Autoproj).should_receive(:error).with('foobar').once
                    flexmock(Main).should_receive(:start)
                                  .with(['update',
                                         '--no-osdeps',
                                         '--no-interactive',
                                         ws.root_dir])
                                  .and_return { raise ArgumentError, 'foobar' }
                    refute cli.update
                    assert cli.update_failed?
                end
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
