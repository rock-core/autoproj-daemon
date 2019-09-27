# frozen_string_literal: true

require 'test_helper'
require 'autoproj/daemon/github_watcher'
require 'timecop'
require 'rubygems/package'
require 'time'
require 'json'

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        describe GithubWatcher do # rubocop: disable Metrics/BlockLength
            attr_reader :watcher
            attr_reader :ws
            before do
                Timecop.freeze(Time.parse('2019-09-22 23:48:00 UTC'))

                @ws = ws_create
                @watcher = GithubWatcher.new(@ws)
                flexmock(watcher).should_receive(:login).and_return(Time.now)
            end

            after do
                Timecop.return
            end

            describe '#add_repository' do
                it 'adds a repository to the watch list' do
                    watcher.add_repository('rock-core', 'autoproj')
                    assert_equal 1, watcher.watched_repositories.size
                    assert_equal 'rock-core', watcher.watched_repositories.first.owner
                    assert_equal 'autoproj', watcher.watched_repositories.first.name
                    assert_equal 'master', watcher.watched_repositories.first.branch
                    assert_equal Time.now.to_f,
                                 watcher.watched_repositories.first.timestamp.to_f
                end
            end

            describe '#handle_events' do # rubocop: disable Metrics/BlockLength
                before do
                    @events = JSON.parse(
                        File.read(File.expand_path('events.json', __dir__))
                    )
                end

                it 'handles latest pull requests' do
                    flexmock(watcher)
                        .should_receive(:pullrequest_open?)
                        .with(any, any).and_return(false)

                    handler = flexmock(interactive?: false)
                    handler.should_receive(:handle)
                           .with('g-arjones/demo_pkg', branch: 'master',
                                                       number: 1).once

                    handler.should_receive(:handle)
                           .with('g-arjones/demo_pkg', branch: 'develop',
                                                       number: 2).once

                    watcher.add_repository('g-arjones', 'demo_pkg', 'master')
                    watcher.add_repository('g-arjones', 'demo_pkg', 'develop')
                    watcher.add_pullrequest_hook do |repo, options|
                        handler.handle(repo, options)
                    end

                    watcher.watched_repositories.each do |repo|
                        watcher.handle_events(repo, @events)
                    end
                end

                # rubocop: disable Metrics/AbcSize
                def push_event_test(owner, name, branch,
                    push_branch, options = {})
                    handler = flexmock(interactive?: false)
                    if options[:never]
                        handler.should_receive(:handle)
                               .with("#{owner}/#{name}", branch: push_branch).never
                    else
                        handler.should_receive(:handle)
                               .with("#{owner}/#{name}", branch: push_branch).once
                    end

                    watcher.add_repository(owner, name, branch)
                    flexmock(watcher)
                        .should_receive(:pullrequest_open?)
                        .with(watcher.watched_repositories[0], "#{owner}:#{push_branch}")
                        .and_return(options[:has_pr])

                    watcher.add_push_hook do |repo_, options_|
                        handler.handle(repo_, options_)
                    end
                    watcher.handle_events(watcher.watched_repositories[0], @events)
                end
                # rubocop: enable Metrics/AbcSize

                it 'handles push events to our branch' do
                    push_event_test(
                        'g-arjones',
                        'demo_pkg',
                        'test_daemon',
                        'test_daemon',
                        has_pr: false
                    )
                end

                it 'handles push events that have a pr open to our branch' do
                    push_event_test(
                        'g-arjones',
                        'demo_pkg',
                        'master',
                        'test_daemon',
                        has_pr: true
                    )
                end

                it 'ignores uninteresting push events' do
                    push_event_test(
                        'g-arjones',
                        'demo_pkg',
                        'master',
                        'test_daemon',
                        has_pr: false,
                        never: true
                    )
                end
            end
        end
    end
end
