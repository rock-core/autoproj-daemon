# frozen_string_literal: true

require "autoproj"
require "autoproj/daemon/github/client"
require "autoproj/daemon/package_repository"
require "autoproj/daemon/github/push_event"
require "autoproj/daemon/github/pull_request_event"
require "date"

module Autoproj
    module Daemon
        # The GithubWatcher will keep an internal list of watched repositories,
        # push hooks and pull request hooks. Whenever an event is detected on a
        # watched repository the corresponding hook is called.
        class GithubWatcher
            attr_reader :cache, :client, :packages, :ws

            # @param [Github::Client] client The github API wrapper
            # @param [Array<PackageRepository>] packages Watched packages
            # @param [Autoproj::Workspace] ws The loaded workspace
            def initialize(client, packages, cache, ws)
                @cache = cache
                @client = client
                @packages = packages
                @ws = ws
                @api_key = ws.config.daemon_api_key
                @polling_period = ws.config.daemon_polling_period
                @hooks = []
            end

            # @return [String] An array with all users that we will be polling
            def owners
                @packages.map(&:owner).uniq
            end

            # Tests whether a repository's branch is one of our package's mainline
            #
            # @param [String] owner
            # @param [String] name
            # @param [String] branch
            def to_mainline?(owner, name, branch)
                packages.any? do |pkg|
                    pkg.owner == owner && pkg.name == name && pkg.branch == branch
                end
            end

            # @return [Array<String>]
            def organizations
                @organizations ||= owners.select { |owner| client.organization?(owner) }
            end

            # Tests whether the given user is an organization
            #
            # @param [String] user
            def organization?(user)
                organizations.include?(user)
            end

            # Tests whether a repository's branch is the source branch of a
            # pull request
            #
            # @param [String] owner
            # @param [String] name
            # @param [String] branch
            def to_pull_request?(owner, name, branch)
                cached_pull_request_affected_by_push_event(owner, name, branch)
            end

            # @api private
            #
            # Lists the pull requests that would be affected by a push to a
            # given target
            #
            # @param [String] owner
            # @param [String] name
            # @param [String] branch
            # @return [PullRequestCache::CachedPullRequest,nil]
            def cached_pull_request_affected_by_push_event(owner, name, branch)
                cache.pull_requests.find do |pr|
                    pr.head_owner == owner &&
                        pr.head_name == name &&
                        pr.head_branch == branch
                end
            end

            # Checks whether an event's creation date is older than the configured
            # daemon_max_age
            #
            # The configuration parameter lies in Autproj's configuration ws.config.
            #
            # @param [Github::PushEvent, Github::PullRequestEvent] event
            def stale?(event)
                (Time.now.to_date - event.created_at.to_date)
                    .round >= ws.config.daemon_max_age
            end

            PartitionedEvents = Struct.new(
                :push_events_to_mainline,
                :push_events_to_pull_request,
                :pull_request_events
            ) do
                # Returns whether this set is empty
                def empty?
                    push_events_to_pull_request.empty? &&
                        push_events_to_mainline.empty? &&
                        pull_request_events.empty?
                end

                # Return all of the events in a single array
                #
                # @return [Array<Github::PullRequestEvent,Github::PushEvent>]
                def all_events
                    push_events_to_pull_request +
                        push_events_to_mainline +
                        pull_request_events
                end
            end

            # @api private
            #
            # Sort received events before further processing
            #
            # @param [Array<Github::PushEvent, Github::PullRequestEvent>] events
            # @param [String,nil] owner if non-nil, only consider events for
            #   repositories owned by it. For pull request events, this is the
            #   base repository.
            # @return [PartitionedEvents]
            def partition_and_filter_events(events, owner: nil)
                filtered = PartitionedEvents.new([], [], [])
                events.each do |event|
                    case event
                    when Github::PushEvent
                        partition_and_filter_push_event(filtered, event, owner: owner)
                    when Github::PullRequestEvent
                        partition_and_filter_pull_request_event(
                            filtered, event, owner: owner
                        )
                    end
                end
                filtered
            end

            # @api private
            #
            # Checks if a push event is useful to us, and partitions it into a
            # {PartitionedEvents} object if it is
            #
            # @param [PartitionedEvents] partitioned_events the structure in which
            #   the event will be sorted.
            # @param [Github::PushEvent] event the event to process
            # @param [String] owner if non-nil, only consider the event if it is
            #   affecting a repository owned by it
            # @return [void]
            def partition_and_filter_push_event(partitioned_events, event, owner: nil)
                return if stale?(event)
                return if owner && event.owner != owner

                if to_mainline?(event.owner, event.name, event.branch)
                    partitioned_events.push_events_to_mainline << event
                elsif to_pull_request?(event.owner, event.name, event.branch)
                    partitioned_events.push_events_to_pull_request << event
                end
            end

            # @api private
            #
            # Checks if a pull request event is useful to us, and partitions it
            # into a {PartitionedEvents} object if it is
            #
            # @param [PartitionedEvents] partitioned_events the structure in which
            #   the event will be sorted.
            # @param [Github::PushEvent] event the event to process
            # @param [String] owner if non-nil, only consider the event if the
            #    pull request's base repository is owned by it
            # @return [void]
            def partition_and_filter_pull_request_event(
                partitioned_events, event, owner: nil
            )
                return if stale?(event)
                return if owner && event.pull_request.base_owner != owner

                pr = event.pull_request
                return unless to_mainline?(pr.base_owner, pr.base_name, pr.base_branch)

                partitioned_events.pull_request_events << event
            end

            # Query Github to find a branch current HEAD SHA
            #
            # @param [String] owner the repository's owner (repo being $owner/$name)
            # @param [String] name the repository's name (repo being $owner/$name)
            # @param [String] branch the branch name
            # @param [Hash] memo a hash allowing to memoize the result, avoiding
            #   to get through the HTTP query stack.
            # @return [String,nil] the HEAD SHA, or nil if the branch does
            #   not seem to exist
            def branch_current_head(owner, name, branch, memo: {})
                branches = (
                    memo[[owner, name]] ||= @client.branches(owner, name)
                )
                branch_state = branches.find { |b| b.branch_name == branch }
                branch_state&.sha
            end

            # Return info about the given pull request
            #
            # @param [String] owner the repository's owner (repo being $owner/$name)
            # @param [String] name the repository's name (repo being $owner/$name)
            # @param [Integer] number the pull request number
            # @param [Hash] memo an optional cache of all pull requests existing
            #   on a given owner and name, to speed up querying multiple pull
            #   requests
            # @return [Github::PullRequest,nil] the pull request, or nil if it does
            #   not seem to exist
            def pull_request_info(owner, name, number, memo: nil)
                if memo
                    cache_key = [owner, name, number]
                    all_prs = (memo[cache_key] ||= client.pull_requests(owner, name))
                    all_prs.find { |p| p.number == number }
                else
                    client.pull_request(owner, name, number)
                end
            end

            # @api private
            #
            # List packages that would be affected by a push on the given
            # repository branch
            #
            # @param [String] owner
            # @param [String] name
            # @param [String] branch
            # @return [PackageRepository, nil]
            def package_affected_by_push_event(owner, name, branch)
                packages.find do |pkg|
                    pkg.owner == owner && pkg.name == name && pkg.branch == branch
                end
            end

            # @api private
            #
            # Process events received for a given user/organization
            #
            # @param [String] owner the user/organization name
            # @param [Array<Github::PushEvent,Github::PullRequestEvent>] events
            # @return [void]
            def handle_owner_events(owner, events)
                events = partition_and_filter_events(events, owner: owner)

                modified_pull_requests = process_modified_pull_requests(events)
                modified_mainlines = process_modified_mainlines(events)

                dispatch(modified_mainlines, modified_pull_requests)
            end

            # @api private
            #
            # Extracts all pull requests that might have been modified by the
            # given events
            #
            # @param [PartitionedEvents] events
            # @return [{Github::PullRequest=>
            #           [Github::PullRequestEvent,Github::PushEvent]}]
            def process_modified_pull_requests(events)
                push_events =
                    events
                    .push_events_to_pull_request
                    .group_by do |e|
                        cached_pull_request_affected_by_push_event(
                            e.owner, e.name, e.branch
                        )
                    end
                push_events.delete(nil)
                pull_request_events =
                    events
                    .pull_request_events
                    .group_by(&:pull_request)

                push_events =
                    push_events
                    .transform_keys { |pr| [pr.base_owner, pr.base_name, pr.number] }
                pull_request_events =
                    pull_request_events
                    .transform_keys { |pr| [pr.base_owner, pr.base_name, pr.number] }
                events = push_events.merge(pull_request_events) { |_, a, b| a + b }

                memo = {}
                events = events
                         .transform_keys { |info| pull_request_info(*info, memo: memo) }
                events.delete(nil)
                events
            end

            # @api private
            #
            # Extracts all packages whose mainline might have been modified by
            # the given events
            #
            # @param [PartitionedEvents] events
            # @return [{PackageRepository=>[GitHub::PushEvent]}]
            def process_modified_mainlines(events)
                per_package =
                    events
                    .push_events_to_mainline
                    .group_by { |e| [e.owner, e.name, e.branch] }

                per_package = per_package.transform_keys do |info|
                    package_affected_by_push_event(*info)
                end

                memo = {}
                per_package.delete_if do |package, _|
                    remote_sha = branch_current_head(
                        package.owner, package.name, package.branch,
                        memo: memo
                    )
                    !remote_sha || (package.head_sha == remote_sha)
                end

                per_package
            end

            # Adds a block that will be called with packages and pull requests
            # that might have been modified according to the event stream
            #
            # @yieldparam [{PackageRepository=>
            #               [GitHub::PushEvent]}] modified_mainlines
            # @yieldparam [{Github::PullRequest=>
            #               [Github::PullRequestEvent,Github::PushEvent]}]
            #               modified_pull_requests
            # @return [void]
            def subscribe(&hook)
                @hooks << hook
            end

            # @api private
            #
            # Dispatch modifications to the hooks registered with {#subscribe}
            #
            # @param [{PackageRepository=>[GitHub::PushEvent]}] modified_mainlines
            # @param [{Github::PullRequest=>[Github::PullRequestEvent,Github::PushEvent]}]
            #   modified_pull_requests
            # @return [void]
            def dispatch(modified_mainlines, modified_pull_requests)
                @hooks.each do |h|
                    h.call(modified_mainlines, modified_pull_requests)
                end
            end

            # Starts watching all repositories
            #
            # This method will loop indefinitely, polling GitHub with the period
            # provided by the user.
            #
            # @return [void]
            def watch
                Autoproj.message "Polling events from #{owners.size} users..."
                latest_events = Hash.new(Time.at(0))

                loop do
                    owners.each do |owner|
                        events = client.fetch_events(
                            owner, organization: organization?(owner)
                        )
                        events = events.sort_by(&:created_at)
                        latest = latest_events[owner]
                        while !events.empty? && events.first.created_at < latest
                            events.shift
                        end
                        next if events.empty?

                        latest_events[owner] = events.last.created_at
                        handle_owner_events(owner, events)
                    end
                    sleep @polling_period
                end
            end
        end
    end
end
