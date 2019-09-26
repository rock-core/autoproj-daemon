# frozen_string_literal: true

require 'autoproj'
require 'octokit'
require 'time'

module Autoproj
    module Daemon
        # The GithubWatcher will keep an internal list of watched repositories,
        # push hooks and pull request hooks. Whenever an event is detected on a
        # watched repository the corresponding hook is called.
        class GithubWatcher
            attr_reader :watched_repositories
            attr_reader :ws

            # @param [Autoproj::Workspace] ws The loaded workspace
            def initialize(ws) # rubocop:disable Naming/UncommunicativeMethodParamName
                @watched_repositories = []
                @ws = ws
                @api_key = ws.config.daemon_api_key
                @polling_period = ws.config.daemon_polling_period
                @client = Octokit::Client.new(access_token: @api_key)
                @client.auto_paginate = true
                @pullrequest_hooks = []
                @push_hooks = []
            end

            # Attempts to authenticate using the configured API key.
            # The API does not require us to aunthenticate first but
            # this is useful so we can get Github's current time.
            #
            # @return [Time] The current time provided by GitHub
            def login
                @client.user.login
                Time.parse(@client.last_response.headers[:date])
            end

            Repository = Struct.new :owner, :name, :branch, :timestamp

            # Adds a repository definition to the internal watch list
            #
            # @param [String] owner The organization/user that the repository belongs to
            # @param [String] name The name of the repository
            # @param [String] branch The branch to watch
            # @return [nil]
            def add_repository(owner, name, branch = 'master')
                @start_time ||= login
                watched_repositories <<
                    Repository.new(owner, name, branch, @start_time)
                nil
            end

            # Adds a block that will be called whenever a pull request is opened
            # in any of the watched repositories.
            #
            # @yield [repo, options] Gives the event description to the block
            # @yieldparam [String] repo The repository name in the format user/repo_name
            # @yieldparam [Hash] options A hash with pull request meta data
            # @return [nil]
            def add_pullrequest_hook(&hook)
                @pullrequest_hooks << hook
                nil
            end

            # Adds a block that will be called whenever a push to a watched branch
            # or to a branch that has a PR open to a watched branch is detected.
            #
            # @yield [repo, options] Gives the event description to the block
            # @yieldparam [String] repo The repository name in the format user/repo_name
            # @yieldparam [Hash] options A hash with push meta data
            # @return [nil]
            def add_push_hook(&hook)
                @push_hooks << hook
                nil
            end

            # Checks whether the given 'head' has a PR open to a watched repository
            #
            # @param [Repository] repo A wacthed repository definition
            # @param [String] head The head definition in the format user:branch
            # @return [Boolean] Whether there's a PR open or not
            def pullrequest_open?(repo, head)
                @client.pull_requests("#{repo.owner}/#{repo.name}",
                                      base: repo.branch).any? do |pr|
                    pr['head']['label'] == head
                end
            end

            REFS_HEADS_RANGE = ('refs/heads/'.length..-1).freeze

            # Handles (by calling all corresponding hooks) a given set
            # of events.
            #
            # @param [Repository] repo A wacthed repository definition
            # @param [Array<Hash>] events Hash with the events returned by the API
            # @return [Integer] The number of handled events
            #
            # rubocop: disable Metrics/AbcSize
            def handle_events(repo, events)
                filter_events(repo, events).each do |event|
                    if event['type'] == 'PullRequestEvent'
                        @pullrequest_hooks.each do |hook|
                            hook.call("#{repo.owner}/#{repo.name}",
                                      branch: repo.branch,
                                      number: event['payload']['number'])
                        end
                    else
                        @push_hooks.each do |hook|
                            hook.call("#{repo.owner}/#{repo.name}",
                                      branch: event['payload']['ref'][REFS_HEADS_RANGE])
                        end
                    end
                end.size
            end
            # rubocop: enable Metrics/AbcSize

            # Whether an event is valid for a given repository
            # A valid event is either a Pull Request or Push that
            # are newer than the last handled event
            #
            # @return [Boolean]
            def valid_event?(repo, event)
                event_types = %w[PullRequestEvent PushEvent]
                return false unless event_types.any? event['type']
                return false if Time.parse(event['created_at'].to_s) < repo.timestamp

                true
            end

            # Filters out uninteresting events for a given repository.
            # This method will return an array with the following events:
            #
            # - Pull Requests to a watched branch
            # - Pushes to a PR that has a watched branch as base
            # - Pushes to a watched branch
            #
            # All events are guaranteed to be newer than the timestamp
            # stored in the repository definition
            #
            # @param [Repository] repo A watched repository
            # @param [Array<Hash>] events The array of events as returned by the API
            # @return [Array<Hash>] A filtered array of events
            #
            # rubocop: disable Metrics/AbcSize
            def filter_events(repo, events)
                events.select do |event|
                    next false unless valid_event?(repo, event)

                    if event['type'] == 'PullRequestEvent'
                        next false unless event['payload']['action'] =~ /opened/
                        next false if event['payload']['pull_request']['base']['ref'] !=
                                      repo.branch
                    else
                        user = event['actor']['login']
                        branch = event['payload']['ref'][REFS_HEADS_RANGE]
                        next event['payload']['ref'] == "refs/heads/#{repo.branch}" ||
                            pullrequest_open?(repo, "#{user}:#{branch}")
                    end
                    true
                end
            end
            # rubocop: enable Metrics/AbcSize

            # Starts watching all repositories
            # This method will loop indefinitely, polling GitHub with the period
            # provided by the user. Once an event is handled, the repository's
            # internal timestamp is updated to prevent the same event from being
            # handled multiple times.
            #
            # @return [nil]
            def watch
                loop do
                    watched_repositories.each do |repo|
                        events = @client.repository_events(
                            "#{repo.owner}/#{repo.name}"
                        )

                        if handle_events(repo, events) > 0
                            repo.timestamp = Time.parse(
                                @client.last_response.headers[:date]
                            )
                        end
                    end
                    sleep @polling_period
                end
                nil
            end
        end
    end
end
