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
                flexmock(Autoproj::Daemon::BuildconfManager)
                    .new_instances.should_receive(:synchronize_branches)
            end

            def define_package(name, vcs)
                pkg = Autoproj::InstallationManifest::Package.new(
                    name, 'Autobuild::CMake', vcs, '/src', '/prefix', '/build', []
                )

                @manifest.add_package(pkg)
            end

            def define_package_set(name, vcs)
                pkg_set = Autoproj::InstallationManifest::PackageSet.new(
                    name, vcs, "/.autoproj/remotes/#{name}", "/autoproj/remotes/#{name}"
                )

                @manifest.add_package_set(pkg_set)
            end

            describe '#resolve_packages' do
                it 'returns an array of all packages and package sets' do
                    pkgs = []
                    pkgs << define_package('foo', type: 'git',
                                                  url: 'https://github.com/owner/foo',
                                                  remote_branch: 'develop')

                    pkgs << define_package('bar', type: 'git',
                                                  url: 'https://github.com/owner/bar',
                                                  remote_branch: 'master')

                    pkgs << define_package_set('core', type: 'git',
                                                       url: 'https://github.com/owner/core',
                                                       remote_branch: 'master')

                    pkgs << define_package_set('utils', type: 'git',
                                                        url: 'https://github.com/owner/utils',
                                                        remote_branch: 'master')

                    assert_equal pkgs, cli.resolve_packages
                end
            end

            describe '#parse_repo_url_from_vcs' do # rubocop: disable Metrics/BlockLength
                it 'parses an http url' do
                    owner, name = cli.parse_repo_url_from_vcs(
                        type: 'git',
                        url: 'http://github.com/rock-core/autoproj'
                    )
                    assert_equal 'rock-core', owner
                    assert_equal 'autoproj', name
                end

                it 'parses a ssh url' do
                    owner, name = cli.parse_repo_url_from_vcs(
                        type: 'git',
                        url: 'git@github.com:rock-core/autoproj'
                    )
                    assert_equal 'rock-core', owner
                    assert_equal 'autoproj', name
                end

                it 'removes git extension from repo name' do
                    owner, name = cli.parse_repo_url_from_vcs(
                        type: 'git',
                        url: 'git@github.com:rock-core/autoproj.git'
                    )
                    assert_equal 'rock-core', owner
                    assert_equal 'autoproj', name
                end

                it 'returns nil for incomplete urls' do
                    assert_nil cli.parse_repo_url_from_vcs(
                        type: 'git',
                        url: 'git@github.com:rock-core/'
                    )
                end

                it 'returns nil if vcs type is not git' do
                    assert_nil cli.parse_repo_url_from_vcs(
                        type: 'archive',
                        url: 'http://github.com/rock-core/autoproj/release/autoproj-2.1.tgz'
                    )
                end
                it 'allows only github urls' do
                    assert_nil cli.parse_repo_url_from_vcs(
                        type: 'git',
                        url: 'git@bitbucket.org:rock-core/autoproj'
                    )
                    assert_nil cli.parse_repo_url_from_vcs(
                        type: 'git',
                        url: 'http://bitbucket.org:rock-core/autoproj'
                    )
                end
            end

            describe '#setup_hooks' do
                it 'updates the workspace on push event' do
                    watcher = flexmock
                    flexmock(cli).should_receive(:watcher).and_return(watcher)
                    watcher.should_receive(:add_push_hook)
                    watcher.should_receive(:add_pull_request_hook)
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

            describe '#packages_to_watch' do
                it 'raises if daemon is not properly configured' do
                    assert_raises(Autoproj::ConfigError) do
                        cli.start
                    end
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
