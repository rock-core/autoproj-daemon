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
            @client.user.login
            @start_time = Time.parse(@client.last_response.headers[:date])
            @pullrequest_hooks = Array.new
        end

        def add_repository(owner, name, branch = 'master')
            watched_repositories << {
                owner: owner,
                name: name,
                branch: branch,
                timestamp: @start_time
            }
        end

        def add_pullrequest_hook(&hook)
            @pullrequest_hooks << hook
            nil
        end

        def handle_events(repo, events)
            events = filter_events(repo, events)
            events.each do |event|
                @pullrequest_hooks.each do |hook|
                    hook.call("#{repo[:owner]}/#{repo[:name]}",
                        branch: repo[:branch],
                        number: event['payload']['number'])
                end
            end
        end

        def filter_events(repo, events)
            events = events.select do |event|
                next false if event['type'] != 'PullRequestEvent'
                next false if Time.parse(event['created_at']) < repo[:timestamp]
                if ((event['type'] == 'PullRequestEvent') &&
                    ((event['payload']['action'] != 'opened') ||
                     (event['payload']['pull_request']['base']['ref'] != repo[:branch])))
                    next false
                end
                true

                # TODO: we should also handle PushEvents if it is a push to our branch
                # or if it is a push to a branch that has a PR open to our branch
            end
        end

        def watch
            loop do
                watched_repositories.each do |repo|
                    events = @client.repository_events(
                        "#{repo[:owner]}/#{repo[:name]}")
                    repo[:timestamp] = Time.parse(
                        @client.last_response.headers[:date])

                    handle_events(repo, events)
                end
                sleep @polling_period
            end
        end
    end
end