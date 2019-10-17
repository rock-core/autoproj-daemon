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
    module Daemon
        describe GithubWatcher do # rubocop: disable Metrics/BlockLength
            attr_reader :watcher
            attr_reader :ws
            before do
                @ws = ws_create
                @client = flexmock(Github::Client.new)
                @cache = PullRequestCache.new(@ws)
                @packages = []
                @watcher = GithubWatcher.new(@client, @packages, @cache, @ws)
            end

            def add_package(pkg_name, owner, name, branch = 'master')
                @packages << PackageRepository.new(pkg_name, owner, name, branch: branch)
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

            describe '#event_owner_and_name' do # rubocop: disable Metrics/BlockLength
                it 'returns the event and owner of a pull request event' do
                    event = create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        created_at: Time.now
                    )

                    owner, name = watcher.event_owner_and_name(event)
                    assert_equal 'rock-core', owner
                    assert_equal 'drivers-gps_ublox', name
                end
                it 'returns the event and owner of a push event' do
                    event = create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        created_at: Time.now
                    )

                    owner, name = watcher.event_owner_and_name(event)
                    assert_equal 'rock-core', owner
                    assert_equal 'drivers-gps_ublox', name
                end
                it 'raises if event is unexpected' do
                    assert_raises ArgumentError do
                        watcher.event_owner_and_name('foo')
                    end
                end
            end
            describe '#to_mainline?' do
                before do
                    add_package('drivers/gps_base', 'rock-core',
                                'drivers-gps_base', 'master')
                end
                it 'returns true if the event is to a mainline branch' do
                    assert watcher.to_mainline?('rock-core', 'drivers-gps_base',
                                                'master')
                end
                it 'returns false if the event is to a feature branch' do
                    refute watcher.to_mainline?('rock-core', 'drivers-gps_base',
                                                'feature')
                end
            end

            describe '#to_pull_request?' do
                before do
                    @pr = create_pull_request(
                        base_owner: 'rock-core',
                        base_name: 'tools-syskit',
                        number: 1,
                        base_branch: 'master',
                        head_owner: 'rock-core',
                        head_name: 'tools-syskit',
                        head_branch: 'feature',
                        head_sha: 'abcdef'
                    )
                    @cache.add(@pr, ['tools-syskit' => { 'remote_branch' => 'feature' }])
                end
                it 'returns true if the event is to a tracked PR' do
                    assert watcher.to_pull_request?('rock-core', 'tools-syskit',
                                                    'feature')
                end
                it 'returns false if the event is to an unkown branch' do
                    refute watcher.to_pull_request?('rock-core', 'tools-syskit',
                                                    'hotfix')
                end
            end

            describe '#filter_events' do # rubocop: disable Metrics/BlockLength
                before do
                    @events = []
                    @events << create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-iodrivers_base',
                        branch: 'master',
                        created_at: Time.now
                    )
                    @events << create_pull_request_event(
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
                    @events << create_push_event(
                        owner: 'rock-core',
                        name: 'tools-syskit',
                        branch: 'feature',
                        created_at: Time.now
                    )
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'tools-syskit',
                                             number: 1,
                                             base_branch: 'master',
                                             head_owner: 'rock-core',
                                             head_name: 'tools-syskit',
                                             head_branch: 'feature',
                                             head_sha: 'abcdef')

                    @cache.add(pr, ['tools-syskit' => { 'remote_branch' => 'feature' }])
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
            describe '#partition_events_by_type' do
                before do
                    @events = []
                    @events << create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-iodrivers_base',
                        branch: 'master',
                        created_at: Time.now
                    )
                    @events << create_pull_request_event(
                        base_owner: 'tidewise',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'feature',
                        created_at: Time.now
                    )
                end
                it 'partitions events by type' do
                    add_package('drivers/iodrivers_base',
                                'rock-core', 'drivers-iodrivers_base')
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox',
                                'feature')

                    pushes, prs = watcher.partition_events_by_type(@events)
                    assert_equal [@events.first], pushes
                    assert_equal [@events.last], prs
                end
            end

            # rubocop: disable Metrics/BlockLength
            describe '#partition_events_by_repo_name' do
                before do
                    @events = []
                    @events << create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-iodrivers_base',
                        branch: 'master',
                        created_at: Time.now
                    )
                    @events << create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        created_at: Time.now
                    )
                    @events << create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        created_at: Time.now
                    )
                end
                it 'partitions events repo name' do
                    add_package('drivers/iodrivers_base',
                                'rock-core', 'drivers-iodrivers_base')
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox')

                    events = watcher.partition_events_by_repo_name(@events)
                    assert_equal events['drivers-iodrivers_base'], [@events.first]
                    assert_equal events['drivers-gps_ublox'], [@events[1], @events[2]]
                end
            end
            # rubocop: enable Metrics/BlockLength

            describe '#package_by_push_event?' do
                before do
                    @pkg = add_package('drivers/gps_base', 'rock-core',
                                       'drivers-gps_base', 'master')
                end
                it 'returns a package definition that is the target of a push event' do
                    event = create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_base',
                        branch: 'master',
                        created_at: Time.now
                    )

                    assert_equal @pkg.first, watcher.package_by_push_event(event)
                end
                it 'returns nil if the push target is an untracked repository' do
                    event = create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-iodrivers_base',
                        branch: 'master',
                        created_at: Time.now
                    )

                    assert_nil watcher.package_by_push_event(event)
                end
            end

            describe '#dispatch_push_event' do # rubocop: disable Metrics/BlockLength
                before do
                    @pkgs = add_package('drivers/gps_base', 'rock-core',
                                        'drivers-gps_base', 'master')
                    flexmock(@pkgs.first).should_receive(:head_sha)
                                         .and_return('abcdef')
                end
                it 'calls push hooks if a mainline push has a different head' do
                    event = create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_base',
                        branch: 'master',
                        head_sha: 'abcdef',
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
                it 'do not call push hooks if the mainline push has the same head' do
                    event = create_push_event(
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
            end

            describe '#handle_owner_events' do # rubocop: disable Metrics/BlockLength
                before do
                    @events = []
                end
                it 'handles the latest push' do # rubocop: disable Metrics/BlockLength
                    @events << create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'master',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )
                    @events << create_push_event(
                        owner: 'rock-core',
                        name: 'drivers-gps_ublox',
                        branch: 'feature',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 45)
                    )
                    pkgs =
                        add_package('drivers/gps_ublox', 'rock-core', 'drivers-gps_ublox')

                    flexmock(pkgs.first).should_receive(:head_sha).and_return('abc')
                    handler = flexmock(interactive?: false)
                    handler.should_receive(:handle).with(@events[1]).once

                    watcher.add_push_hook do |event|
                        handler.handle(event)
                    end
                    watcher.handle_owner_events(@events)
                end
                it 'does not dispatch nil push events' do
                    @events << create_pull_request_event(
                        base_owner: 'tidewise',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox')
                    flexmock(watcher).should_receive(:dispatch_push_event)
                                     .with(any).never
                    watcher.handle_owner_events(@events)
                end
                # rubocop: disable Metrics/BlockLength
                it 'handles the latest pull request' do
                    @events << create_pull_request_event(
                        base_owner: 'tidewise',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << create_pull_request_event(
                        base_owner: 'tidewise',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )
                    @events << create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_base',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 45)
                    )
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox')
                    add_package('drivers/gps_base', 'rock-core', 'drivers-gps_base')

                    handler = flexmock
                    handler.should_receive(:handle).with(@events[1]).once
                    handler.should_receive(:handle).with(@events[2]).once

                    watcher.add_pull_request_hook do |event|
                        handler.handle(event)
                    end
                    watcher.handle_owner_events(@events)
                end
                it 'handles close events of cached pull requests' do
                    @events << create_pull_request_event(
                        base_owner: 'tidewise',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'close',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox')
                    @cache.add(@events.first.pull_request, [])

                    handler = flexmock
                    handler.should_receive(:handle).with(@events[0]).once

                    watcher.add_pull_request_hook do |event|
                        handler.handle(event)
                    end
                    watcher.handle_owner_events(@events)
                end
                it 'ignores close events of untracked pull requests' do
                    @events << create_pull_request_event(
                        base_owner: 'tidewise',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'close',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    add_package('drivers/gps_ublox', 'tidewise', 'drivers-gps_ublox')

                    handler = flexmock
                    handler.should_receive(:handle).with(@events[0]).never
                    watcher.add_pull_request_hook do |event|
                        handler.handle(event)
                    end
                    watcher.handle_owner_events(@events)
                end
                # rubocop: enable Metrics/BlockLength
            end
        end
    end
end
