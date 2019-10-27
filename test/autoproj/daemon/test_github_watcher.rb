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
                        head_owner: 'contributor',
                        head_name: 'tools-syskit_fork',
                        head_branch: 'feature',
                        head_sha: 'abcdef'
                    )
                    @cache.add(@pr, ['tools-syskit' => { 'remote_branch' => 'feature' }])
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
                    @pr = create_pull_request(
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
                        @pr, ['tools-syskit' => { 'remote_branch' => 'feature' }]
                    )
                end
                it 'returns the cached pull request that is affected by a push' do
                    event = create_push_event(
                        owner: 'contributor',
                        name: 'tools-syskit_fork',
                        branch: 'feature',
                        created_at: Time.now
                    )
                    assert_equal @cached,
                                 watcher.cached_pull_request_affected_by_push_event(event)
                end
                it 'returns nil if the event does not affect any pull request' do
                    event = create_push_event(
                        owner: 'contributor',
                        name: 'tools-roby',
                        branch: 'feature',
                        created_at: Time.now
                    )
                    assert_nil watcher.cached_pull_request_affected_by_push_event(event)
                end
            end
            # rubocop: enable Metrics/BlockLength

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

            describe '#package_affected_by_push_event?' do
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

                    assert_equal @pkg, watcher.package_affected_by_push_event(event)
                end
                it 'returns nil if the push target is an untracked repository' do
                    event = create_push_event(
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

                    flexmock(@pkg).should_receive(:head_sha).and_return('abcdef')
                end
                it 'calls push hooks if a mainline push has a different head' do
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
                it 'do not call push hooks if the mainline push has the same head' do
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
                # rubocop: disable Metrics/BlockLength
                it 'calls push hooks if push is to an open pull request' do
                    pr = create_pull_request(
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

                    event = create_push_event(
                        owner: 'contributor',
                        name: 'drivers-gps_base',
                        branch: 'feature',
                        head_sha: 'eghijk',
                        created_at: Time.now + 2
                    )

                    @cache.add(
                        pr,
                        ['drivers-gps_base' => { 'remote_branch' => 'feature' }]
                    )

                    handler = flexmock
                    handler.should_receive(:handle).with(event, mainline: false,
                                                                pull_request: pr).once
                    watcher.add_push_hook do |push_event, **options|
                        handler.handle(push_event, options)
                    end

                    flexmock(watcher.client).should_receive(:pull_request)
                                            .with('rock-core', 'drivers-gps_base', 1)
                                            .and_return(pr)

                    watcher.dispatch_push_event(event)
                end
                it 'does not call push hooks if push is to a closed pull request' do
                    pr = create_pull_request(
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

                    event = create_push_event(
                        owner: 'contributor',
                        name: 'drivers-gps_base',
                        branch: 'feature',
                        head_sha: 'eghijk',
                        created_at: Time.now + 2
                    )

                    @cache.add(
                        pr,
                        ['drivers-gps_base' => { 'remote_branch' => 'feature' }]
                    )

                    handler = flexmock
                    handler.should_receive(:handle).with(event, mainline: false,
                                                                pull_request: pr).never
                    watcher.add_push_hook do |push_event, **options|
                        handler.handle(push_event, options)
                    end

                    flexmock(watcher.client).should_receive(:pull_request)
                                            .with('rock-core', 'drivers-gps_base', 1)
                                            .and_return(pr)

                    watcher.dispatch_push_event(event)
                end
                it 'does not call push hooks if push is to a PR that no longer exists' do
                    pr = create_pull_request(
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

                    event = create_push_event(
                        owner: 'contributor',
                        name: 'drivers-gps_base',
                        branch: 'feature',
                        head_sha: 'eghijk',
                        created_at: Time.now + 2
                    )

                    @cache.add(
                        pr,
                        ['drivers-gps_base' => { 'remote_branch' => 'feature' }]
                    )

                    handler = flexmock
                    handler.should_receive(:handle).with(event, mainline: false,
                                                                pull_request: pr).never
                    watcher.add_push_hook do |push_event, **options|
                        handler.handle(push_event, options)
                    end

                    flexmock(watcher.client).should_receive(:pull_request)
                                            .with('rock-core', 'drivers-gps_base', 1)
                                            .and_return(nil)

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
                    @events << create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )

                    add_package('drivers/gps_ublox', 'rock-core', 'drivers-gps_ublox')
                    @events[2..3].each { |event| @cache.add(event.pull_request, []) }

                    flexmock(watcher)
                        .should_receive(:handle_push_events)
                        .with(@events[0..1]).once

                    flexmock(watcher)
                        .should_receive(:handle_pull_request_events)
                        .with(@events[2..3]).once

                    watcher.handle_owner_events(@events)
                end
                it 'does not call push handler if there are no events to be handled' do
                    @events << create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )

                    add_package('drivers/gps_ublox', 'rock-core', 'drivers-gps_ublox')
                    @events[0..1].each { |event| @cache.add(event.pull_request, []) }

                    flexmock(watcher).should_receive(:handle_push_events).with(any).never
                    flexmock(watcher)
                        .should_receive(:handle_pull_request_events)
                        .with(@events[0..1]).once

                    watcher.handle_owner_events(@events)
                end
                it 'does not call PR handler if there are no PR events' do
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

                    add_package('drivers/gps_ublox', 'rock-core', 'drivers-gps_ublox')
                    flexmock(watcher)
                        .should_receive(:handle_push_events)
                        .with(@events[0..1]).once

                    flexmock(watcher)
                        .should_receive(:handle_pull_request_events)
                        .with(any).never

                    watcher.handle_owner_events(@events)
                end
                # rubocop: enable Metrics/BlockLength
            end

            describe '#handle_push_events' do # rubocop: disable Metrics/BlockLength
                before do
                    @events = []
                end
                # rubocop: disable Metrics/BlockLength
                it 'handles the latest push for each repo and branch' do
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
                        name: 'drivers-gps_base',
                        branch: 'master',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 45)
                    )
                    @events << create_push_event(
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
                    @events << create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        number: 1,
                        state: 'closed',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_ublox',
                        base_branch: 'master',
                        number: 1,
                        state: 'open',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 40)
                    )
                    @events << create_pull_request_event(
                        base_owner: 'rock-core',
                        base_name: 'drivers-gps_base',
                        number: 2,
                        base_branch: 'master',
                        state: 'closed',
                        created_at: Time.utc(2019, 'sep', 22, 23, 53, 35)
                    )
                    @events << create_pull_request_event(
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
                    @events << create_pull_request_event(
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
                    @events << create_pull_request_event(
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
