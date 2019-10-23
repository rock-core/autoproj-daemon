# frozen_string_literal: true

require 'autoproj'
require 'autoproj/daemon/github/client'
require 'autoproj/daemon/package_repository'
require 'autoproj/daemon/github/push_event'
require 'autoproj/daemon/github/pull_request_event'

module Autoproj
    module Daemon
        # The GithubWatcher will keep an internal list of watched repositories,
        # push hooks and pull request hooks. Whenever an event is detected on a
        # watched repository the corresponding hook is called.
        class GithubWatcher
            attr_reader :cache
            attr_reader :client
            attr_reader :packages
            attr_reader :ws

            # @param [Github::Client] client The github API wrapper
            # @param [Array<PackageRepository>] packages Watched packages
            # @param [Autoproj::Workspace] ws The loaded workspace
            # rubocop:disable Naming/UncommunicativeMethodParamName
            def initialize(client, packages, cache, ws)
                @cache = cache
                @client = client
                @packages = packages
                @ws = ws
                @api_key = ws.config.daemon_api_key
                @polling_period = ws.config.daemon_polling_period
                @pull_request_hooks = []
                @push_hooks = []
            end
            # rubocop:enable Naming/UncommunicativeMethodParamName

            # @return [String] An array with all users that we will be polling
            def owners
                @packages.map(&:owner).uniq
            end

            # @param [String] owner
            # @param [String] name
            # @param [String] branch
            # @return [Boolean]
            def to_mainline?(owner, name, branch)
                packages.any? do |pkg|
                    pkg.owner == owner && pkg.name == name && pkg.branch == branch
                end
            end

            # @param [String] owner
            # @param [String] name
            # @param [String] branch
            # @return [Boolean]
            def to_pull_request?(owner, name, branch)
                cache.pull_requests.any? do |pr|
                    pr.head_owner == owner && pr.head_name == name &&
                        pr.head_branch == branch
                end
            end

            # @param [Github::PushEvent] event
            # @return [PullRequestCache::CachedPullRequest, nil]
            def cached_pull_request_affected_by_push_event(event)
                cache.pull_requests.find do |pr|
                    pr.head_owner == event.owner &&
                        pr.head_name == event.name &&
                        pr.head_branch == event.branch
                end
            end

            # @param [Array<Github::PushEvent, Github::PullRequestEvent>] events
            # @return [Array<Github::PushEvent, Github::PullRequestEvent>]
            def filter_events(events)
                events.select do |event|
                    case event
                    when Github::PushEvent
                        to_mainline?(event.owner, event.name, event.branch) ||
                            to_pull_request?(event.owner, event.name, event.branch)
                    when Github::PullRequestEvent
                        pr = event.pull_request
                        to_mainline?(pr.base_owner, pr.base_name, pr.base_branch)
                    end
                end
            end

            # @param [Github::PushEvent] push_event
            # @return [void]
            def call_push_hooks(push_event, **options)
                @push_hooks.each { |hook| hook.call(push_event, options) }
            end

            # @param [Github::PullRequestEvent] pull_request_event
            # @return [void]
            def call_pull_request_hooks(pull_request_event)
                @pull_request_hooks.each { |hook| hook.call(pull_request_event) }
            end

            # @param [Github::PushEvent] push_event
            # @return [PackageRepository, nil]
            def package_affected_by_push_event(push_event)
                packages.find do |pkg|
                    pkg.owner == push_event.owner &&
                        pkg.name == push_event.name &&
                        pkg.branch == push_event.branch
                end
            end

            # @param [Github::PushEvent] push_event
            # @return [void]
            def dispatch_push_event(push_event)
                to_mainline = to_mainline?(
                    push_event.owner, push_event.name, push_event.branch
                )
                if to_mainline
                    package = package_affected_by_push_event(push_event)
                    return if package.head_sha == push_event.head_sha
                else
                    cached_pull_request =
                        cached_pull_request_affected_by_push_event(push_event)

                    pull_request = client.pull_request(
                        cached_pull_request.base_owner,
                        cached_pull_request.base_name,
                        cached_pull_request.number
                    )
                    return unless pull_request&.open?
                end
                call_push_hooks(push_event, mainline: to_mainline,
                                            pull_request: pull_request)
            end

            # @param [Array] events An array of events
            # @return [void]
            def handle_owner_events(events)
                events = filter_events(events)
                push_events, pull_request_events =
                    events.partition { |event| event.kind_of? Github::PushEvent }

                handle_push_events(push_events) unless push_events.empty?
                return if pull_request_events.empty?

                handle_pull_request_events(pull_request_events)
            end

            # @param [Array<Github::PushEvent>]
            # @return [void]
            def handle_push_events(events)
                events = events.group_by(&:name)
                events.each_value do |repo_events|
                    repo_events = repo_events.group_by(&:branch)
                    repo_events.each_value do |branch_events|
                        latest_event = branch_events.max_by(&:created_at)
                        dispatch_push_event(latest_event)
                    end
                end
            end

            # @param [Array<Github::PullRequestEvent>]
            # @return [void]
            def handle_pull_request_events(events)
                events = events.group_by { |event| event.pull_request.base_name }
                events.each_value do |repo_events|
                    repo_events =
                        repo_events.group_by { |event| event.pull_request.number }

                    repo_events.each_value do |pull_request_events|
                        latest_event = pull_request_events.max_by(&:created_at)
                        call_pull_request_hooks(latest_event)
                    end
                end
            end

            # Adds a block that will be called whenever a pull request is opened
            # in any of the watched repositories.
            #
            # @yield [repo, options] Gives the event description to the block
            # @yieldparam [String] repo The repository name in the format user/repo_name
            # @yieldparam [Hash] options A hash with pull request meta data
            # @return [void]
            def add_pull_request_hook(&hook)
                @pull_request_hooks << hook
            end

            # Adds a block that will be called whenever a push to a watched branch
            # or to a branch that has a PR open to a watched branch is detected.
            #
            # @yield [repo, options] Gives the event description to the block
            # @yieldparam [String] repo The repository name in the format user/repo_name
            # @yieldparam [Hash] options A hash with push meta data
            # @return [void]
            def add_push_hook(&hook)
                @push_hooks << hook
            end

            # Starts watching all repositories
            # This method will loop indefinitely, polling GitHub with the period
            # provided by the user.
            #
            # @return [void]
            def watch
                loop do
                    owners.each do |owner|
                        handle_owner_events(client.fetch_events(owner))
                    end
                    sleep @polling_period
                end
            end
        end
    end
end
