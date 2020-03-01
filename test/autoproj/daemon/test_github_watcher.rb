# frozen_string_literal: true

require 'test_helper'
require 'autoproj/daemon/pull_request_cache'
require 'autoproj/daemon/github_watcher'
require 'autoproj/daemon/github/push_event'
require 'autoproj/daemon/github/pull_request_event'
require 'rubygems/package'

# Autoproj's main module
module Autoproj
    # Daemon main module
    # rubocop: disable Metrics/ModuleLength
    module Daemon
        describe GithubWatcher do # rubocop: disable Metrics/BlockLength
            attr_reader :watcher
            include Autoproj::Daemon::TestHelpers

            before do
                autoproj_daemon_mock_github_api
                autoproj_daemon_create_ws(
                    type: 'git',
                    url: 'git@github.com:rock-core/buildconf'
                )

                @ws.config.daemon_polling_period = 0
                @packages = []

                @client = Github::Client.new
                @cache = PullRequestCache.new(@ws)
                @watcher = GithubWatcher.new(@client, @packages, @cache, @ws)

                autoproj_daemon_define_user('rock-core', type: 'Organization')
                autoproj_daemon_define_user('tidewise', type: 'Organization')
                autoproj_daemon_define_user('g-arjones', type: 'User')

                flexmock(watcher).should_receive(:loop).explicitly.and_yield # loop once
                flexmock(Time).should_receive(:now)
                              .and_return(Time.utc(2019, 'oct', 20, 0, 0, 0))
            end

            def add_package(pkg_name, owner, name, branch = 'master')
                pkg = autoproj_daemon_add_package(
                    pkg_name,
                    type: 'git',
                    url: "https://github.com/#{owner}/#{name}",
                    branch: branch
                )

                @packages << PackageRepository.new(
                    pkg_name, owner, name, pkg.vcs.to_hash, ws: ws, local_dir: pkg.srcdir
                )

                @packages.last
            end

            describe '#owners' do
                it 'returns the list of watched users' do
                    add_package('drivers/gps_base', 'rock-core', 'drivers-gps_base')
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox')
                    add_package('drivers/iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base')

                    assert_equal %w[rock-core tidewise], watcher.owners
                end
            end

            describe '#organizations' do
                it 'returns the list of users that are an organization' do
                    add_package('drivers/gps_base', 'rock-core', 'drivers-gps_base')
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox')
                    add_package('drivers/iodrivers_base', 'g-arjones',
                                'drivers-iodrivers_base')

                    assert_equal %w[rock-core tidewise], watcher.organizations
                    assert watcher.organization?('rock-core')
                    assert watcher.organization?('tidewise')
                    refute watcher.organization?('g-arjones')
                end
            end

            describe '#watch' do
                it 'passes organization flag to the client' do
                    add_package('drivers/gps_base', 'rock-core', 'drivers-gps_base')
                    add_package('tools/roby', 'g-arjones', 'tools-roby')

                    flexmock(@client).should_receive(:fetch_events)
                                     .with('rock-core', organization: true)
                                     .once.and_return([])

                    flexmock(@client).should_receive(:fetch_events)
                                     .with('g-arjones', organization: false)
                                     .once.and_return([])

                    watcher.watch
                end
            end

            describe '#to_mainline?' do
                before do
                    add_package('drivers/gps_base', 'rock-core',
                                'drivers-gps_base', 'master')
                end
                it 'returns true if the event is to a mainline branch' do
                    assert watcher.to_mainline?('rock-core', 'drivers-gps_base', 'master')
                end
                it 'returns false if the event is to a feature branch' do
                    refute watcher.to_mainline?('rock-core', 'drivers-gps_base', 'feat')
                end
            end

            describe '#to_pull_request?' do # rubocop: disable Metrics/BlockLength
                before do
                    @pr = autoproj_daemon_add_pull_request(
                        base_owner: 'rock-core',
                        base_name: 'tools-syskit',
                        number: 1,
                        base_branch: 'master',
                        head_owner: 'contributor',
                        head_name: 'tools-syskit_fork',
                        head_branch: 'feature',
                        head_sha: 'abcdef'
                    )
                    @cache.add(
                        @pr,
                        [
                            'tools-syskit' => {
                                'remote_branch' => 'refs/pull/1/merge'
                            }
                        ]
                    )
                end
                it 'returns true if the event is to a tracked PR' do
                    assert watcher.to_pull_request?('contributor', 'tools-syskit_fork',
                                                    'feature')
                end
                it 'returns false if the event is NOT to a tracked PR' do
                    refute watcher.to_pull_request?('rock-core', 'tools-syskit',
                                                    'feature2')
                end
            end

            # rubocop: disable Metrics/BlockLength
            describe '#cached_pull_request_affected_by_push_event' do
                before do
                    @pr = autoproj_daemon_add_pull_request(
                        base_owner: 'rock-core',
                        base_name: 'tools-syskit',
                        number: 1,
                        base_branch: 'master',
                        head_owner: 'contributor',
                        head_name: 'tools-syskit_fork',
                        head_branch: 'feature',
                        head_sha: 'abcdef'
                    )
                    @cached = @cache.add(
                        @pr,
                        [
                            'tools-syskit' => {
                                'remote_branch' => 'refs/pull/1/merge'
                            }
                        ]
                    )
                end
                it 'returns the cached pull request that is affected by a push' do
                    event = autoproj_daemon_add_push_event(
                        owner: 'contributor',
                        name: 'tools-syskit_fork',
                        branch: 'feature',
                        created_at: Time.now
                    )
                    assert_equal @cached,
                                 watcher.cached_pull_request_affected_by_push_event(event)
                end
                it 'returns nil if the event does not affect any pull request' do
                    event = autoproj_daemon_add_push_event(
                        owner: 'contributor',
                        name: 'tools-roby',
                        branch: 'feature',
                        created_at: Time.now
                    )
                    assert_nil watcher.cached_pull_request_affected_by_push_event(event)
                end
            end

            describe '#filter_events' do # rubocop: disable Metrics/BlockLength
                before do
                    @events = []
                    @events << autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-iodrivers_base',
                        branch: 'master',
                        created_at: Time.now
                    )
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'tidewise',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'feature',
                        created_at: Time.now
                    )
                end
                it 'removes events that are not pushes or pull requests' do
                    @events << String.new
                    add_package('drivers/iodrivers_base',
                                'rock-core', 'drivers-iodrivers_base')
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox',
                                'feature')

                    events = watcher.filter_events(@events)
                    assert_equal 2, events.size
                    assert_equal events.first, @events[0]
                    assert_equal events.last, @events[1]
                end
                it 'reject events that are too old' do
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'tools-roby',
                        base_branch: 'master',
                        created_at: Time.new(1990, 1, 1)
                    )
                    add_package('tools/roby', 'rock-core', 'tools-roby')
                    events = watcher.filter_events(@events)

                    assert_equal 0, events.size
                end
                it 'filters relevant pull requests' do
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox',
                                'feature')

                    events = watcher.filter_events(@events)
                    assert_equal 1, events.size
                    assert_equal events.first, @events.last
                end
                it 'filters relevant pushes' do
                    add_package('drivers/iodrivers_base',
                                'rock-core', 'drivers-iodrivers_base')

                    events = watcher.filter_events(@events)
                    assert_equal 1, events.size
                    assert_equal events.first, @events.first
                end
                it 'filters pushes to a watched PR' do
                    @events << autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'tools-syskit',
                        branch: 'feature',
                        created_at: Time.now
                    )
                    pr = autoproj_daemon_add_pull_request(
                        base_owner: 'rock-core',
                        base_name: 'tools-syskit',
                        number: 1,
                        base_branch: 'master',
                        head_owner: 'rock-core',
                        head_name: 'tools-syskit',
                        head_branch: 'feature',
                        head_sha: 'abcdef'
                    )

                    @cache.add(
                        pr,
                        [
                            'tools-syskit' => {
                                'remote_branch' => 'refs/pull/1/merge'
                            }
                        ]
                    )

                    events = watcher.filter_events(@events)
                    assert_equal 1, events.size
                    assert_equal events.first, @events.last
                end
                it 'removes pushes if branches are different' do
                    add_package('drivers/iodrivers_base',
                                'rock-core', 'drivers-iodrivers_base', 'develop')

                    events = watcher.filter_events(@events)
                    assert events.empty?
                end
                it 'removes pushes if owners are different' do
                    add_package('drivers/iodrivers_base',
                                'tidewise', 'drivers-iodrivers_base')

                    events = watcher.filter_events(@events)
                    assert events.empty?
                end
                it 'removes pushes if names are different' do
                    add_package('drivers/iodrivers_base',
                                'rock-core', 'drivers-iodrivers_base2')

                    events = watcher.filter_events(@events)
                    assert events.empty?
                end
                it 'removes pull requests if branches are different' do
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox')
                    events = watcher.filter_events(@events)
                    assert events.empty?
                end
                it 'removes pull requests if owners are different' do
                    add_package('drivers/gps_ublox', 'rock-core', 'drivers-gps_ublox',
                                'feature')

                    events = watcher.filter_events(@events)
                    assert events.empty?
                end
                it 'removes pull requests if names are different' do
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox2',
                                'feature')

                    events = watcher.filter_events(@events)
                    assert events.empty?
                end
            end
            # rubocop: enable Metrics/BlockLength

            describe '#package_affected_by_push_event?' do
                before do
                    @pkg = add_package('drivers/gps_base', 'rock-core',
                                       'drivers-gps_base', 'master')
                end
                it 'returns a package definition that is the target of a push event' do
                    event = autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_base',
                        branch: 'master',
                        created_at: Time.now
                    )

                    assert_equal @pkg, watcher.package_affected_by_push_event(event)
                end
                it 'returns nil if the push target is an untracked repository' do
                    event = autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-iodrivers_base',
                        branch: 'master',
                        created_at: Time.now
                    )

                    assert_nil watcher.package_affected_by_push_event(event)
                end
            end

            describe '#dispatch_push_event' do # rubocop: disable Metrics/BlockLength
                before do
                    @pkg = add_package('drivers/gps_base', 'rock-core',
                                       'drivers-gps_base', 'master')
                end
                it 'calls push hooks if a mainline push has a different head' do
                    event = autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_base',
                        branch: 'master',
                        head_sha: 'eghijk',
                        created_at: Time.now
                    )

                    handler = flexmock
                    handler.should_receive(:handle).with(event, mainline: true,
                                                                pull_request: nil).once

                    watcher.add_push_hook do |push_event, **options|
                        handler.handle(push_event, options)
                    end

                    watcher.dispatch_push_event(event)
                end
                it 'do not call push hooks if the mainline push has the same head' do
                    pkg = @packages.find { |p| p.package == 'drivers/gps_base' }
                    event = autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_base',
                        branch: 'master',
                        head_sha: pkg.head_sha,
                        created_at: Time.now
                    )

                    handler = flexmock
                    handler.should_receive(:handle).with(event, mainline: true,
                                                                pull_request: nil).never

                    watcher.add_push_hook do |push_event, **options|
                        handler.handle(push_event, options)
                    end

                    watcher.dispatch_push_event(event)
                end

                # rubocop: disable Metrics/BlockLength
                it 'calls push hooks if push is to an open pull request' do
                    pr = autoproj_daemon_add_pull_request(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_base',
                        number: 1,
                        base_branch: 'master',
                        head_owner: 'contributor',
                        head_name: 'drivers-gps_base',
                        head_branch: 'feature',
                        head_sha: 'eghijk',
                        state: 'open'
                    )

                    event = autoproj_daemon_add_push_event(
                        owner: 'contributor',
                        name: 'drivers-gps_base',
                        branch: 'feature',
                        head_sha: 'eghijk',
                        created_at: Time.now + 2
                    )

                    @cache.add(
                        pr,
                        [
                            'drivers-gps_base' => {
                                'remote_branch' => 'refs/pull/1/merge'
                            }
                        ]
                    )

                    handler = flexmock
                    handler.should_receive(:handle).with(event, mainline: false,
                                                                pull_request: pr).once

                    watcher.add_push_hook do |push_event, **options|
                        handler.handle(push_event, options)
                    end

                    watcher.dispatch_push_event(event)
                end
                it 'does not call push hooks if push is to a closed pull request' do
                    pr = autoproj_daemon_add_pull_request(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_base',
                        number: 1,
                        base_branch: 'master',
                        head_owner: 'contributor',
                        head_name: 'drivers-gps_base',
                        head_branch: 'feature',
                        head_sha: 'eghijk',
                        state: 'closed'
                    )

                    event = autoproj_daemon_add_push_event(
                        owner: 'contributor',
                        name: 'drivers-gps_base',
                        branch: 'feature',
                        head_sha: 'eghijk',
                        created_at: Time.now + 2
                    )

                    @cache.add(
                        pr,
                        [
                            'drivers-gps_base' => {
                                'remote_branch' => 'refs/pull/1/merge'
                            }
                        ]
                    )

                    handler = flexmock
                    handler.should_receive(:handle).with(event, mainline: false,
                                                                pull_request: pr).never

                    watcher.add_push_hook do |push_event, **options|
                        handler.handle(push_event, options)
                    end

                    watcher.dispatch_push_event(event)
                end
                it 'does not call push hooks if push is to a PR that no longer exists' do
                    pr = autoproj_daemon_add_pull_request(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_base',
                        number: 1,
                        base_branch: 'master',
                        head_owner: 'contributor',
                        head_name: 'drivers-gps_base',
                        head_branch: 'feature',
                        head_sha: 'eghijk',
                        state: 'closed'
                    )

                    event = autoproj_daemon_add_push_event(
                        owner: 'contributor',
                        name: 'drivers-gps_base',
                        branch: 'feature',
                        head_sha: 'eghijk',
                        created_at: Time.now + 2
                    )

                    @cache.add(
                        pr,
                        [
                            'drivers-gps_base' => {
                                'remote_branch' => 'feature'
                            }
                        ]
                    )

                    handler = flexmock
                    handler.should_receive(:handle).with(event, mainline: false,
                                                                pull_request: pr).never

                    watcher.add_push_hook do |push_event, **options|
                        handler.handle(push_event, options)
                    end

                    watcher.dispatch_push_event(event)
                end
                # rubocop: enable Metrics/BlockLength
            end

            describe '#handle_owner_events' do # rubocop: disable Metrics/BlockLength
                before do
                    @events = []
                end
                # rubocop: disable Metrics/BlockLength
                it 'calls the right handler for the kind of event' do
                    @events << autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        head_sha: '1234',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        head_sha: 'abcd',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )

                    autoproj_daemon_add_branch(
                        'rock-core', 'drivers-gps_ublox',
                        branch_name: 'master', sha: 'abcd'
                    )
                    add_package('drivers/gps_ublox', 'rock-core', 'drivers-gps_ublox')
                    @events[2..3].each { |event| @cache.add(event.pull_request, []) }

                    flexmock(watcher)
                        .should_receive(:handle_push_events)
                        .with(@events[1, 1]).once

                    flexmock(watcher)
                        .should_receive(:handle_pull_request_events)
                        .with(@events[2, 2]).once

                    watcher.handle_owner_events('rock-core', @events)
                end
                it 'ignores events on third-party repos' do
                    @events << autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )

                    add_package('drivers/gps_ublox', 'rock-core', 'drivers-gps_ublox')
                    @cache.add(@events[1].pull_request, [])

                    flexmock(watcher)
                        .should_receive(:handle_push_events)
                        .with([]).once

                    flexmock(watcher)
                        .should_receive(:handle_pull_request_events)
                        .with([]).once

                    watcher.handle_owner_events('tidewise', @events)
                end
                it 'updates the event\'s SHA using the current branch state' do
                    ev = autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        head_sha: '1234',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << ev
                    autoproj_daemon_add_branch(
                        'rock-core', 'drivers-gps_ublox',
                        branch_name: 'master', sha: '3456'
                    )

                    add_package('drivers/gps_ublox', 'rock-core', 'drivers-gps_ublox')

                    expected_ev = ev.dup
                    expected_ev.head_sha = '3456'
                    flexmock(watcher)
                        .should_receive(:handle_push_events)
                        .with([expected_ev]).once

                    watcher.handle_owner_events('rock-core', @events)
                end
                # rubocop: enable Metrics/BlockLength
            end

            describe '#handle_push_events' do # rubocop: disable Metrics/BlockLength
                before do
                    @events = []
                end
                # rubocop: disable Metrics/BlockLength
                it 'handles the latest push for each repo and branch' do
                    @events << autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )
                    @events << autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_base',
                        branch: 'master',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 45)
                    )
                    @events << autoproj_daemon_add_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_base',
                        branch: 'master',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 50)
                    )
                    flexmock(watcher).should_receive(:dispatch_push_event)
                                     .with(@events[1]).once

                    flexmock(watcher).should_receive(:dispatch_push_event)
                                     .with(@events[3]).once

                    watcher.handle_push_events(@events)
                end
                # rubocop: enable Metrics/BlockLength
            end

            # rubocop: disable Metrics/BlockLength
            describe '#handle_pull_request_events' do
                before do
                    @events = []
                end
                it 'handles the latest event for each repo and PR' do
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        number: 1,
                        state: 'closed',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        number: 1,
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_base',
                        number: 2,
                        base_branch: 'master',
                        state: 'closed',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_base',
                        base_branch: 'master',
                        number: 2,
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )

                    flexmock(watcher).should_receive(:call_pull_request_hooks)
                                     .with(@events[1]).once

                    flexmock(watcher).should_receive(:call_pull_request_hooks)
                                     .with(@events[3]).once

                    watcher.handle_pull_request_events(@events)
                end
                it 'handles close events of cached PRs' do
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        number: 1,
                        state: 'closed',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @cache.add(@events[0].pull_request, [])

                    flexmock(watcher).should_receive(:call_pull_request_hooks)
                                     .with(@events[0]).once

                    watcher.handle_pull_request_events(@events)
                end
                it 'ignores close events of unknown PRs' do
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        number: 1,
                        state: 'closed',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    flexmock(watcher).should_receive(:call_pull_request_hooks)
                                     .with(@events[0]).never

                    watcher.handle_pull_request_events(@events)
                end
                # rubocop: enable Metrics/BlockLength
            end
        end
    end
    # rubocop: enable Metrics/ModuleLength
end
