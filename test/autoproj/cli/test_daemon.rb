# frozen_string_literal: true

require 'test_helper'
require 'autoproj/cli/main'
require 'autoproj/daemon/package_repository'
require 'autoproj/daemon/github_watcher'
require 'octokit'
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

            describe '#handle_push_event' do # rubocop: disable Metrics/BlockLength
                before do
                    @push_event = create_push_event(owner: 'rock-core',
                                                    name: 'drivers-iodrivers_base',
                                                    branch: 'master',
                                                    created_at: Time.now)
                end
                describe 'a push on a mainline branch' do
                    it 'triggers build, restarts daemon and updates the workspace' do
                        flexmock(cli.bb).should_receive(:build).once
                        flexmock(cli).should_receive(:restart_and_update).once.ordered
                        cli.handle_push_event(@push_event, mainline: true)
                    end
                end
                # rubocop: disable Metrics/BlockLength
                describe 'a push on a pull request branch' do
                    before do
                        @pull_request = create_pull_request(
                            base_owner: 'rock-core',
                            base_name: 'drivers-iodrivers_base',
                            base_branch: 'master',
                            head_owner: 'rock-core',
                            head_name: 'drivers-iodrivers_base',
                            head_branch: 'feature',
                            head_sha: 'abcdef',
                            number: 1
                        )
                        @overrides = [
                            {
                                'drivers-iodrivers_base' => {
                                    'remote_branch' => 'feature'
                                }
                            }
                        ]
                        @buildconf_manager = flexmock
                        flexmock(cli).should_receive(:buildconf_manager)
                                     .and_return(@buildconf_manager)
                    end
                    it 'does not update buildconf branch if PR did not change' do
                        cli.cache.add(@pull_request, @overrides)
                        @buildconf_manager.should_receive(:overrides_for_pull_request)
                                          .with(@pull_request).and_return(@overrides)

                        @buildconf_manager.should_receive(:commit_and_push_overrides)
                                          .never
                        cli.handle_push_event(@push_event, mainline: false,
                                                           pull_request: @pull_request)
                    end
                    it 'updates buildconf branch and cache if PR changed' do
                        cli.cache.add(@pull_request, @overrides)
                        @buildconf_manager.should_receive(:overrides_for_pull_request)
                                          .with(@pull_request).and_return([])

                        @buildconf_manager.should_receive(:commit_and_push_overrides).once

                        branch_name = 'autoproj/rock-core/drivers-iodrivers_base/pulls/1'
                        flexmock(cli.bb).should_receive(:build)
                                        .with(branch: branch_name).once

                        cli.handle_push_event(@push_event, mainline: false,
                                                           pull_request: @pull_request)

                        refute cli.cache.changed?(@pull_request, [])
                    end
                end
                # rubocop: enable Metrics/BlockLength
            end

            # rubocop: disable Metrics/BlockLength
            describe '#handle_pull_request_event' do
                before do
                    @pull_request = create_pull_request(
                        base_owner: 'rock-core',
                        base_name: 'drivers-iodrivers_base',
                        base_branch: 'master',
                        head_owner: 'rock-core',
                        head_name: 'drivers-iodrivers_base',
                        head_branch: 'feature',
                        head_sha: 'abcdef',
                        state: 'open',
                        number: 1
                    )

                    @pull_request_event = create_pull_request_event(
                        owner: 'rock-core',
                        name: 'drivers-iodrivers_base',
                        branch: 'master',
                        pull_request: @pull_request,
                        created_at: Time.now
                    )

                    @buildconf_package = Autoproj::Daemon::PackageRepository.new(
                        'main configuration',
                        'rock-core',
                        'buildconf',
                        branch: 'master'
                    )

                    @buildconf_manager = flexmock
                    flexmock(cli).should_receive(:buildconf_package)
                                 .and_return(@buildconf_package)
                    flexmock(cli).should_receive(:buildconf_manager)
                                 .and_return(@buildconf_manager)

                    @buildconf_manager.should_receive(:overrides_for_pull_request)
                                      .with(@pull_request).and_return([])
                end
                describe 'a PR is opened' do
                    it 'does not update buildconf branch if the PR did not change' do
                        cli.cache.add(@pull_request, [])
                        @buildconf_manager.should_receive(:commit_and_push_overrides)
                                          .never

                        cli.handle_pull_request_event(@pull_request_event)
                    end
                    it 'updates buildconf branch and cache if the PR changed' do
                        cli.cache.add(
                            @pull_request,
                            [{ 'package' => { 'remote_branch' => 'something' } }]
                        )

                        branch_name = 'autoproj/rock-core/drivers-iodrivers_base/pulls/1'
                        flexmock(cli.bb).should_receive(:build)
                                        .with(branch: branch_name).once

                        @buildconf_manager.should_receive(:commit_and_push_overrides).once
                        cli.handle_pull_request_event(@pull_request_event)
                        refute cli.cache.changed?(@pull_request, [])
                    end
                end
                describe 'a PR is closed' do
                    before do
                        @model = @pull_request.instance_variable_get(:@model)
                        @model['state'] = 'closed'

                        @pull_request_event = create_pull_request_event(
                            owner: 'rock-core',
                            name: 'drivers-iodrivers_base',
                            branch: 'master',
                            pull_request: @pull_request,
                            created_at: Time.now
                        )
                    end
                    it 'handles errors if buildconf branch does not exist' do
                        flexmock(cli).should_receive('client.delete_branch_by_name')
                                     .with('rock-core', 'buildconf',
                                           'autoproj/rock-core/'\
                                           'drivers-iodrivers_base/pulls/1')
                                     .and_raise(Octokit::UnprocessableEntity)

                        cli.handle_pull_request_event(@pull_request_event)
                    end
                    it 'deletes branch and removes PR from cache' do
                        cli.cache.add(@pull_request, [])

                        flexmock(cli).should_receive('client.delete_branch_by_name')
                                     .with('rock-core', 'buildconf',
                                           'autoproj/rock-core/drivers-iodrivers_base/'\
                                           'pulls/1')

                        refute cli.cache.changed?(@pull_request, [])
                        cli.handle_pull_request_event(@pull_request_event)
                        assert cli.cache.changed?(@pull_request, [])
                    end
                end
            end
            # rubocop: enable Metrics/BlockLength

            describe '#setup_hooks' do
                it 'sets up push and pull request handlers' do
                    watcher = flexmock
                    flexmock(cli).should_receive(:watcher).and_return(watcher)

                    watcher.should_receive(:add_push_hook)
                           .and_yield('push_event', options: 'options')
                    watcher.should_receive(:add_pull_request_hook)
                           .and_yield('pull_request_event')

                    flexmock(cli).should_receive(:handle_push_event)
                                 .with('push_event', options: 'options').once
                    flexmock(cli).should_receive(:handle_pull_request_event)
                                 .with('pull_request_event').once

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

            describe '#configure' do
                it 'configures daemon' do
                    flexmock(ws.config)
                        .should_receive(:configure).with('daemon_api_key').once
                    flexmock(ws.config)
                        .should_receive(:configure).with('daemon_polling_period')
                        .at_least.once
                    flexmock(ws.config)
                        .should_receive(:configure).with('daemon_buildbot_host')
                        .at_least.once
                    flexmock(ws.config)
                        .should_receive(:configure).with('daemon_buildbot_port')
                        .at_least.once
                    flexmock(ws.config)
                        .should_receive(:configure).with('daemon_buildbot_scheduler')
                        .at_least.once
                    cli.configure
                end
            end
        end
    end
end
