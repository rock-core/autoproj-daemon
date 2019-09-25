require 'autoproj'
require 'octokit'
require 'time'

module Autoproj
    class GithubWatcher
        attr_reader :watched_repositories
        attr_reader :ws

        def initialize(ws)
            @watched_repositories = []
            @ws = ws
            @api_key = ws.config.daemon_api_key
            @polling_period = ws.config.daemon_polling_period
            @client = Octokit::Client.new(access_token: @api_key)
            @client.auto_paginate = true
            @pullrequest_hooks = Array.new
            @push_hooks = Array.new
        end

        def login
            @client.user.login
            Time.parse(@client.last_response.headers[:date])
        end

        Repository = Struct.new :owner, :name, :branch, :timestamp

        def add_repository(owner, name, branch = 'master')
            @start_time ||= login
            watched_repositories <<
                Repository.new(owner, name, branch, @start_time)
        end

        def add_pullrequest_hook(&hook)
            @pullrequest_hooks << hook
            nil
        end

        def add_push_hook(&hook)
            @push_hooks << hook
            nil
        end

        def has_pullrequest_open?(repo)
            @client.pull_requests("#{repo.owner}/#{repo.name}",
                base: repo.branch).size > 0
        end

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
                    next has_pullrequest_open?(repo) ||
                        "refs/heads/#{repo.branch}" == event['payload']['ref']
                end
                true
            end
        end

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
        end
    end
end