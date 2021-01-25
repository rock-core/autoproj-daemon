# frozen_string_literal: true

require "test_helper"
require "autoproj/daemon/pull_request_cache"
require "autoproj/daemon/github_watcher"
require "autoproj/daemon/github/push_event"
require "autoproj/daemon/github/pull_request_event"
require "rubygems/package"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        describe GithubWatcher do
            attr_reader :watcher

            include Autoproj::Daemon::TestHelpers

            before do
                autoproj_daemon_mock_github_api
                autoproj_daemon_create_ws(
                    type: "git",
                    url: "git@github.com:rock-core/buildconf"
                )

                @ws.config.daemon_polling_period = 0
                @packages = [autoproj_daemon_buildconf_package]

                @client = Github::Client.new
                @cache = PullRequestCache.new(@ws)
                @watcher = GithubWatcher.new(@client, @packages, @cache, @ws)

                autoproj_daemon_define_user("rock-core", type: "Organization")
                autoproj_daemon_define_user("tidewise", type: "Organization")
                autoproj_daemon_define_user("g-arjones", type: "User")

                flexmock(watcher).should_receive(:loop).explicitly.and_yield # loop once
                flexmock(Time).should_receive(:now)
                              .and_return(Time.utc(2019, "oct", 20, 0, 0, 0))
            end

            def add_package(pkg_name, owner, name, branch = "master")
                pkg = autoproj_daemon_add_package(
                    pkg_name,
                    type: "git",
                    url: "https://github.com/#{owner}/#{name}",
                    branch: branch
                )

                @packages << PackageRepository.new(
                    pkg_name, owner, name, pkg.vcs.to_hash,
                    ws: ws, local_dir: pkg.srcdir
                )

                @packages.last
            end

            describe "#owners" do
                it "returns the list of watched users" do
                    add_package("drivers/gps_base", "rock-core", "drivers-gps_base")
                    add_package("drivers/gps_ublox", "tidewise", "drivers-gps_ublox")
                    add_package("drivers/iodrivers_base", "rock-core",
                                "drivers-iodrivers_base")

                    assert_equal %w[rock-core tidewise], watcher.owners
                end
            end

            describe "#organizations" do
                it "returns the list of users that are an organization" do
                    add_package("drivers/gps_base", "rock-core", "drivers-gps_base")
                    add_package("drivers/gps_ublox", "tidewise", "drivers-gps_ublox")
                    add_package("drivers/iodrivers_base", "g-arjones",
                                "drivers-iodrivers_base")

                    assert_equal %w[rock-core tidewise], watcher.organizations
                    assert watcher.organization?("rock-core")
                    assert watcher.organization?("tidewise")
                    refute watcher.organization?("g-arjones")
                end
            end

            describe "#watch" do
                it "passes organization flag to the client" do
                    add_package("drivers/gps_base", "rock-core", "drivers-gps_base")
                    add_package("tools/roby", "g-arjones", "tools-roby")

                    flexmock(@client).should_receive(:fetch_events)
                                     .with("rock-core", organization: true)
                                     .once.and_return([])

                    flexmock(@client).should_receive(:fetch_events)
                                     .with("g-arjones", organization: false)
                                     .once.and_return([])

                    watcher.watch
                end
            end

            describe "#to_mainline?" do
                before do
                    add_package("drivers/gps_base", "rock-core",
                                "drivers-gps_base", "master")
                end
                it "returns true if the event is to a mainline branch" do
                    assert watcher.to_mainline?("rock-core", "drivers-gps_base", "master")
                end
                it "returns false if the event is to a feature branch" do
                    refute watcher.to_mainline?("rock-core", "drivers-gps_base", "feat")
                end
            end

            describe "#to_pull_request?" do
                before do
                    @pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "tools-syskit",
                        number: 1,
                        base_branch: "master",
                        head_owner: "contributor",
                        head_name: "tools-syskit_fork",
                        head_branch: "feature",
                        head_sha: "abcdef"
                    )
                    @cache.add(
                        @pr,
                        [
                            "tools-syskit" => {
                                "remote_branch" => "refs/pull/1/merge"
                            }
                        ]
                    )
                end
                it "returns true if the event is to a tracked PR" do
                    assert watcher.to_pull_request?("contributor", "tools-syskit_fork",
                                                    "feature")
                end
                it "returns false if the event is NOT to a tracked PR" do
                    refute watcher.to_pull_request?("rock-core", "tools-syskit",
                                                    "feature2")
                end
            end
            describe "#cached_pull_request_affected_by_push_event" do
                before do
                    @pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "tools-syskit",
                        number: 1,
                        base_branch: "master",
                        head_owner: "contributor",
                        head_name: "tools-syskit_fork",
                        head_branch: "feature",
                        head_sha: "abcdef"
                    )
                    @cached = @cache.add(
                        @pr,
                        [
                            "tools-syskit" => {
                                "remote_branch" => "refs/pull/1/merge"
                            }
                        ]
                    )
                end
                it "returns the cached pull request that is affected by a push" do
                    pr = watcher.cached_pull_request_affected_by_push_event(
                        "contributor", "tools-syskit_fork", "feature"
                    )
                    assert_equal @cached, pr
                end
                it "returns nil if the event does not affect any pull request" do
                    pr = watcher.cached_pull_request_affected_by_push_event(
                        "contributor", "tools-roby", "feature"
                    )
                    assert_nil pr
                end
            end

            describe "#partition_and_filter_events" do
                before do
                    @events = []
                    @events << autoproj_daemon_add_push_event(
                        owner: "rock-core",
                        name: "drivers-iodrivers_base",
                        branch: "master",
                        created_at: Time.now
                    )
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: "tidewise",
                        base_name: "drivers-gps_ublox",
                        base_branch: "feature",
                        created_at: Time.now
                    )
                end
                it "removes events that are not pushes or pull requests" do
                    @events << String.new
                    add_package("drivers/iodrivers_base",
                                "rock-core", "drivers-iodrivers_base")
                    add_package("drivers/gps_ublox", "tidewise", "drivers-gps_ublox",
                                "feature")

                    events = watcher.partition_and_filter_events(@events).all_events
                    assert_equal 2, events.size
                    assert_equal events.first, @events[0]
                    assert_equal events.last, @events[1]
                end
                it "reject events that are too old" do
                    @events << autoproj_daemon_add_pull_request_event(
                        base_owner: "rock-core",
                        base_name: "tools-roby",
                        base_branch: "master",
                        created_at: Time.new(1990, 1, 1)
                    )
                    add_package("tools/roby", "rock-core", "tools-roby")
                    events = watcher.partition_and_filter_events(@events).all_events

                    assert_equal 0, events.size
                end
                it "filters relevant pull requests" do
                    add_package("drivers/gps_ublox", "tidewise", "drivers-gps_ublox",
                                "feature")

                    events = watcher.partition_and_filter_events(@events)
                                    .pull_request_events
                    assert_equal 1, events.size
                    assert_equal events.first, @events.last
                end
                it "filters relevant pushes" do
                    add_package("drivers/iodrivers_base",
                                "rock-core", "drivers-iodrivers_base")

                    events = watcher.partition_and_filter_events(@events)
                                    .push_events_to_mainline
                    assert_equal 1, events.size
                    assert_equal events.first, @events.first
                end
                it "filters pushes to a watched PR" do
                    @events << autoproj_daemon_add_push_event(
                        owner: "rock-core",
                        name: "tools-syskit",
                        branch: "feature",
                        created_at: Time.now
                    )
                    pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "tools-syskit",
                        number: 1,
                        base_branch: "master",
                        head_owner: "rock-core",
                        head_name: "tools-syskit",
                        head_branch: "feature",
                        head_sha: "abcdef"
                    )

                    @cache.add(
                        pr,
                        [
                            "tools-syskit" => {
                                "remote_branch" => "refs/pull/1/merge"
                            }
                        ]
                    )

                    events = watcher.partition_and_filter_events(@events)
                                    .push_events_to_pull_request
                    assert_equal 1, events.size
                    assert_equal events.first, @events.last
                end
                it "removes pull request pushes if the base branch is not our mainline" do
                    add_package("drivers/iodrivers_base",
                                "rock-core", "drivers-iodrivers_base", "develop")

                    events = watcher.partition_and_filter_events(@events)
                    assert events.empty?
                end
                it "removes pushes if owners are different" do
                    add_package("drivers/iodrivers_base",
                                "tidewise", "drivers-iodrivers_base")

                    events = watcher.partition_and_filter_events(@events)
                    assert events.empty?
                end
                it "removes pushes if names are different" do
                    add_package("drivers/iodrivers_base",
                                "rock-core", "drivers-iodrivers_base2")

                    events = watcher.partition_and_filter_events(@events)
                    assert events.empty?
                end
                it "removes pull request events if branches are different" do
                    add_package("drivers/gps_ublox", "tidewise", "drivers-gps_ublox")
                    events = watcher.partition_and_filter_events(@events)
                    assert events.empty?
                end
                it "removes pull requests if owners are different" do
                    add_package("drivers/gps_ublox", "rock-core", "drivers-gps_ublox",
                                "feature")

                    events = watcher.partition_and_filter_events(@events)
                    assert events.empty?
                end
                it "removes pull requests if names are different" do
                    add_package("drivers/gps_ublox", "tidewise", "drivers-gps_ublox2",
                                "feature")

                    events = watcher.partition_and_filter_events(@events)
                    assert events.empty?
                end
            end

            describe "#package_affected_by_push_event" do
                before do
                    @pkg = add_package("drivers/gps_base", "rock-core",
                                       "drivers-gps_base", "master")
                end
                it "returns a package definition that is the target of a push event" do
                    package = watcher.package_affected_by_push_event(
                        "rock-core", "drivers-gps_base", "master"
                    )
                    assert_equal @pkg, package
                end
                it "returns nil if the push target is an untracked repository" do
                    package = watcher.package_affected_by_push_event(
                        "rock-core", "drivers-iodrivers_base", "master"
                    )
                    assert_nil package
                end
                it "handles the build configuration itself" do
                    package = watcher.package_affected_by_push_event(
                        "rock-core", "buildconf", "master"
                    )
                    assert_equal autoproj_daemon_buildconf_package, package
                end
            end

            describe "#process_modified_pull_requests" do
                before do
                    @pkg = add_package("drivers/gps_base", "rock-core",
                                       "drivers-gps_base", "master")

                    @pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-gps_base",
                        number: 1,
                        base_branch: "master",
                        head_owner: "contributor",
                        head_name: "drivers-gps_base",
                        head_branch: "feature",
                        head_sha: "eghijk",
                        state: "open"
                    )
                end

                it "returns the pull requests for the push events" do
                    event = autoproj_daemon_add_push_event(
                        owner: "contributor",
                        name: "drivers-gps_base",
                        branch: "feature",
                        head_sha: "eghijk",
                        created_at: Time.now + 2
                    )
                    events = GithubWatcher::PartitionedEvents.new([], [event], [])
                    @cache.add(@pr, [])
                    pull_requests = watcher.process_modified_pull_requests(events)
                    assert_equal({ @pr => [event] }, pull_requests)
                end

                it "returns the pull requests for the pull request events" do
                    event = autoproj_daemon_add_pull_request_event(
                        base_owner: "rock-core",
                        base_name: "drivers-gps_base",
                        base_branch: "master",
                        state: "open",
                        number: 1,
                        created_at: Time.utc(2019, "sep", 22, 23, 53, 35)
                    )
                    events = GithubWatcher::PartitionedEvents.new([], [], [event])
                    @cache.add(@pr, [])
                    pull_requests = watcher.process_modified_pull_requests(events)
                    assert_equal({ @pr => [event] }, pull_requests)
                end

                it "ignores push events whose pull request is not yet in cache" do
                    event = autoproj_daemon_add_push_event(
                        owner: "contributor",
                        name: "drivers-gps_base",
                        branch: "feature",
                        head_sha: "eghijk",
                        created_at: Time.now + 2
                    )
                    events = GithubWatcher::PartitionedEvents.new([], [event], [])
                    pull_requests = watcher.process_modified_pull_requests(events)
                    assert_equal({}, pull_requests)
                end

                it "returns a given pull request only once" do
                    e0 = autoproj_daemon_add_push_event(
                        owner: "contributor",
                        name: "drivers-gps_base",
                        branch: "feature",
                        head_sha: "eghijk",
                        created_at: Time.now + 2
                    )
                    e1 = autoproj_daemon_add_pull_request_event(
                        base_owner: "rock-core",
                        base_name: "drivers-gps_base",
                        base_branch: "master",
                        state: "open",
                        number: 1,
                        created_at: Time.now + 3
                    )
                    events = GithubWatcher::PartitionedEvents.new([], [e0], [e1])
                    @cache.add(@pr, [])
                    pull_requests = watcher.process_modified_pull_requests(events)
                    assert_equal({ @pr => [e0, e1] }, pull_requests)
                end
            end

            describe "#process_modified_mainlines" do
                before do
                    @pkg = add_package("drivers/gps_base", "rock-core",
                                       "drivers-gps_base", "master")
                    @event = autoproj_daemon_add_push_event(
                        owner: "rock-core",
                        name: "drivers-gps_base",
                        branch: "master",
                        head_sha: "efohai",
                        created_at: Time.now
                    )
                end

                it "returns the affected packages" do
                    autoproj_daemon_add_branch(
                        "rock-core", "drivers-gps_base",
                        branch_name: "master", sha: "somethingsomething"
                    )

                    events = GithubWatcher::PartitionedEvents.new([@event], [], [])
                    packages = watcher.process_modified_mainlines(events)
                    assert_equal({ @pkg => [@event] }, packages)
                end

                it "returns nothing if the remote branch does not exist" do
                    events = GithubWatcher::PartitionedEvents.new([@event], [], [])
                    packages = watcher.process_modified_mainlines(events)
                    assert packages.empty?
                end

                it "returns nothing if the current remote SHA matches the package's" do
                    autoproj_daemon_add_branch(
                        "rock-core", "drivers-gps_base",
                        branch_name: "master", sha: @pkg.head_sha
                    )

                    events = GithubWatcher::PartitionedEvents.new([@event], [], [])
                    packages = watcher.process_modified_mainlines(events)
                    assert packages.empty?
                end

                it "returns a package only once" do
                    event1 = autoproj_daemon_add_push_event(
                        owner: "rock-core",
                        name: "drivers-gps_base",
                        branch: "master",
                        head_sha: "egedrohigf",
                        created_at: (Time.now + 1)
                    )
                    autoproj_daemon_add_branch(
                        "rock-core", "drivers-gps_base",
                        branch_name: "master", sha: "somethingsomething"
                    )

                    events = GithubWatcher::PartitionedEvents.new(
                        [@event, event1], [], []
                    )
                    packages = watcher.process_modified_mainlines(events)
                    assert_equal({ @pkg => [@event, event1] }, packages)
                end
            end

            describe "#handle_owner_events" do
                it "partitions events, resolves packages and PRs and forwards them" do
                    events = []
                    events << autoproj_daemon_add_push_event(
                        owner: "rock-core",
                        name: "drivers-gps_ublox",
                        branch: "master",
                        head_sha: "1234",
                        created_at: Time.utc(2019, "sep", 22, 23, 53, 35)
                    )
                    events << autoproj_daemon_add_push_event(
                        owner: "rock-core",
                        name: "drivers-gps_ublox",
                        branch: "master",
                        head_sha: "abcd",
                        created_at: Time.utc(2019, "sep", 22, 23, 53, 40)
                    )
                    events << autoproj_daemon_add_pull_request_event(
                        base_owner: "rock-core",
                        base_name: "drivers-gps_ublox",
                        base_branch: "master",
                        state: "open",
                        number: 1,
                        created_at: Time.utc(2019, "sep", 22, 23, 53, 35)
                    )
                    events << autoproj_daemon_add_pull_request_event(
                        base_owner: "rock-core",
                        base_name: "drivers-gps_ublox",
                        base_branch: "master",
                        state: "open",
                        number: 2,
                        created_at: Time.utc(2019, "sep", 22, 23, 53, 40)
                    )

                    autoproj_daemon_add_branch(
                        "rock-core", "drivers-gps_ublox",
                        branch_name: "master", sha: "abcd"
                    )
                    pr0 = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core", base_name: "drivers-gps_ublox",
                        base_branch: "master", number: 1, sha: "abcd"
                    )
                    pr1 = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core", base_name: "drivers-gps_ublox",
                        base_branch: "master", number: 2, sha: "abcd"
                    )
                    pkg = add_package(
                        "drivers/gps_ublox", "rock-core", "drivers-gps_ublox"
                    )
                    events[2..3].each { |event| @cache.add(event.pull_request, []) }

                    received_packages, received_pull_requests = nil
                    watcher.subscribe do |packages, pull_requests|
                        received_packages = packages
                        received_pull_requests = pull_requests
                    end

                    watcher.handle_owner_events("rock-core", events)

                    assert_equal({ pkg => events[0, 2] }, received_packages)
                    assert_equal({ pr0 => [events[2]], pr1 => [events[3]] },
                                 received_pull_requests)
                end
            end
        end
    end
end
