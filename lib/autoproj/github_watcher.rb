require 'autoproj'
require 'octokit'
require 'time'

module Autoproj
    # The GithubWatcher will keep an internal list of watched repositories,
    # push hooks and pull request hooks. Whenever an event is detected on a
    # watched repository the corresponding hook is called.
    class GithubWatcher
        attr_reader :watched_repositories
        attr_reader :ws

        # @param [Autoproj::Workspace] ws The loaded workspace
        def initialize(ws)
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
        def has_pullrequest_open?(repo, head)
            @client.pull_requests("#{repo.owner}/#{repo.name}",
                base: repo.branch).any? do |pr|
                    pr['head']['label'] == head
                end
        end

        # Handles (by calling all corresponding hooks) a given set
        # of events.
        #
        # @param [Repository] repo A wacthed repository definition
        # @param [Array<Hash>] events Hash with the events returned by the API
        # @return [Integer] The number of handled events
        def handle_events(repo, events)
            events = filter_events(repo, events)
            events.each do |event|
                if event['type'] == 'PullRequestEvent'
                    @pullrequest_hooks.each do |hook|
                        hook.call("#{repo.owner}/#{repo.name}",
                            branch: repo.branch,
                            number: event['payload']['number'])
                    end
                end
                if event['type'] == 'PushEvent'
                    @push_hooks.each do |hook|
                        refs_heads = "refs/heads/"
                        hook.call("#{repo.owner}/#{repo.name}",
                            branch: event['payload']['ref'][refs_heads.length..-1])
                    end
                end
            end.size
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
        def filter_events(repo, events)
            event_types = %w[PullRequestEvent PushEvent]
            events = events.select do |event|
                next false unless event_types.any? event['type']
                next false if Time.parse(event['created_at'].to_s) < repo.timestamp
                if (event['type'] == 'PullRequestEvent')
                    next false unless event['payload']['action'] =~ /opened/
                    next false if event['payload']['pull_request']['base']['ref'] != repo.branch
                end
                if (event['type'] == 'PushEvent')
                    refs_heads = "refs/heads/"
                    user = event['actor']['login']
                    branch =  event['payload']['ref'][refs_heads.length..-1]
                    next "refs/heads/#{repo.branch}" == event['payload']['ref'] ||
                        has_pullrequest_open?(repo, "#{user}:#{branch}")
                end
                true
            end
        end

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
                        "#{repo.owner}/#{repo.name}")

                    if handle_events(repo, events) > 0
                        repo.timestamp = Time.parse(
                            @client.last_response.headers[:date])
                    end
                end
                sleep @polling_period
            end
            nil
        end
    end
end