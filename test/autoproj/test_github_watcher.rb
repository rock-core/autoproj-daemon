require 'test_helper'
require 'autoproj/github_watcher'
require 'timecop'
require 'rubygems/package'
require 'time'
require 'json'

module Autoproj
    describe GithubWatcher do
        attr_reader :watcher
        attr_reader :ws
        before do
            @ws = ws_create
            Timecop.freeze(Time.parse("2019-09-22 23:48:00 UTC"))
            mock_github_client
            @watcher = GithubWatcher.new(@ws)
        end

        after do
            Timecop.return
        end

        describe '#add_repository' do
            it 'adds a repository to the watch list' do
                watcher.add_repository('rock-core', 'autoproj')
                assert_equal 1, watcher.watched_repositories.size
                assert_equal 'rock-core', watcher.watched_repositories.first[:owner]
                assert_equal 'autoproj', watcher.watched_repositories.first[:name]
                assert_equal 'master', watcher.watched_repositories.first[:branch]
                assert_equal Time.now.to_f, watcher.watched_repositories.first[:timestamp].to_f
            end
        end

        describe '#handle_events' do
            before do
                @events = JSON.load(File.read(File.expand_path('events.json', __dir__)))
            end

            it 'handles latest pull requests' do
                handler = flexmock(interactive?: false)
                handler.should_receive(:handle).with("g-arjones/demo_pkg",
                    branch: 'master',
                    number: 1).once

                watcher.add_repository('g-arjones', 'demo_pkg', 'master')
                watcher.add_pullrequest_hook do |repo, options|
                    handler.handle(repo, options)
                end

                watcher.handle_events(
                    watcher.watched_repositories.first,
                    @events)
            end
        end
    end
end
