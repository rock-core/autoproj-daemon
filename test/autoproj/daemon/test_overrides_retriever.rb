# frozen_string_literal: true

require "autoproj/daemon/overrides_retriever"
require "test_helper"

module Autoproj
    # Main daemon module
    module Daemon
        describe OverridesRetriever do
            # @return [Autoproj::Daemon::OverridesRetriever]
            attr_reader :retriever

            # @return [Autoproj::Daemon::GitAPI::Client]
            attr_reader :client

            include Autoproj::Daemon::TestHelpers
            before do
                autoproj_daemon_create_ws(type: "git",
                                          url: "git@github.com:rock-core/buildconf.git")

                ws.config.daemon_set_service("github.com", "apikey")
                ws.config.daemon_set_service("gitlab.com", "apikey")

                autoproj_daemon_mock_git_api
                @client = GitAPI::Client.new(@ws)
                @retriever = OverridesRetriever.new(client)
                @pull_requests = {}
            end

            def add_pull_request(owner, name, number, body, state: "open")
                autoproj_daemon_add_pull_request(
                    repo_url: "git@github.com:#{owner}/#{name}",
                    body: body,
                    number: number,
                    state: state
                )
            end

            def create_pull_request(owner, name, number, body, state: "open")
                autoproj_daemon_create_pull_request(
                    repo_url: "git@github.com:#{owner}/#{name}",
                    body: body,
                    number: number,
                    state: state
                )
            end

            describe "#parse_task_list" do
                it "parses the list of pending tasks" do
                    body = <<~EOFBODY
                        Depends on:

                        - [ ] one
                        - [ ] two
                        - [x] three
                        - [ ] four
                    EOFBODY

                    tasks = []
                    tasks << "one"
                    tasks << "two"
                    tasks << "four"

                    assert_equal tasks, retriever.parse_task_list(body)
                end
                it "only parses the first list" do
                    body = <<~EOFBODY
                        Depends on:
                        - [ ] one._1

                        List of something else, not dependencies:
                        - [ ] two
                    EOFBODY

                    tasks = []
                    tasks << "one._1"
                    assert_equal tasks, retriever.parse_task_list(body)
                end
                it "allows multilevel task lists" do
                    body = <<~EOFBODY
                        Depends on:
                        - 1. Feature 1:
                          - [ ] one
                          - [ ] two

                        - [ ] Feature 2:
                          - [x] three
                          - [ ] four
                    EOFBODY

                    tasks = []
                    tasks << "one"
                    tasks << "two"
                    tasks << "Feature"
                    tasks << "four"
                    assert_equal tasks, retriever.parse_task_list(body)
                end
            end
            describe "#task_to_pull_request" do
                attr_reader :pr

                before do
                    @pr = add_pull_request("g-arjones._1", "demo.pkg_1", 22, "")
                end
                it "returns nil if the PR cannot be found" do
                    assert_nil retriever.task_to_pull_request(
                        "https://github.com/g-arjones/demo_pkg/pull/66", pr
                    )
                end
                it "returns nil if the resource does not exist" do
                    client.should_receive(:pull_requests)
                          .with(any).and_raise(GitAPI::NotFound)

                    assert_nil retriever.task_to_pull_request(
                        "https://github.com/g-arjones/demo_pkg/pull/66", pr
                    )
                end
            end
            describe "#retrieve_dependencies" do
                it "recursively fetches pull request dependencies" do
                    body_driver_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] tidewise/drivers-orogen-gps_ublox#22
                    EOFBODY
                    pr_drivers_gps_ublox = add_pull_request(
                        "tidewise", "drivers-gps_ublox",
                        11, body_driver_gps_ublox
                    )

                    body_driver_orogen_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] rock-core/drivers-orogen-iodrivers_base#33
                        - [ ] tidewise/tidewise.common-package_set#44
                    EOFBODY
                    pr_driver_orogen_gps_ublox = add_pull_request(
                        "tidewise", "drivers-orogen-gps_ublox",
                        22, body_driver_orogen_gps_ublox
                    )

                    pr_driver_orogen_iodrivers_base = add_pull_request(
                        "rock-core", "drivers-orogen-iodrivers_base",
                        33, nil
                    )
                    pr_package_set = add_pull_request(
                        "tidewise", "tidewise.common-package_set",
                        44, nil
                    )

                    depends = retriever.retrieve_dependencies(pr_drivers_gps_ublox)
                    assert_equal [pr_driver_orogen_gps_ublox,
                                  pr_driver_orogen_iodrivers_base,
                                  pr_package_set], depends
                end
                it "breaks cyclic dependencies" do
                    body_driver_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] tidewise/drivers-orogen-gps_ublox#22
                    EOFBODY
                    pr_drivers_gps_ublox = add_pull_request(
                        "tidewise", "drivers-gps_ublox",
                        11, body_driver_gps_ublox
                    )

                    body_driver_orogen_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] tidewise/drivers-gps_ublox#11
                    EOFBODY
                    pr_driver_orogen_gps_ublox = add_pull_request(
                        "tidewise", "drivers-orogen-gps_ublox",
                        22, body_driver_orogen_gps_ublox
                    )

                    depends = retriever.retrieve_dependencies(pr_drivers_gps_ublox)
                    assert_equal [pr_driver_orogen_gps_ublox], depends
                end
                it "does not add same PR twice" do
                    body_driver_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] tidewise/drivers-orogen-gps_ublox#22
                        - [ ] rock-core/base-cmake#44
                    EOFBODY
                    pr_drivers_gps_ublox = add_pull_request(
                        "tidewise", "drivers-gps_ublox",
                        11, body_driver_gps_ublox
                    )

                    body_driver_orogen_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] rock-core/base-cmake#44
                    EOFBODY
                    pr_driver_orogen_gps_ublox = add_pull_request(
                        "tidewise", "drivers-orogen-gps_ublox",
                        22, body_driver_orogen_gps_ublox
                    )

                    pr_base_cmake = add_pull_request(
                        "rock-core", "base-cmake",
                        44, nil
                    )

                    depends = retriever.retrieve_dependencies(pr_drivers_gps_ublox)
                    assert_equal [pr_driver_orogen_gps_ublox,
                                  pr_base_cmake], depends
                end
                it "allows depending on pull requests from different services" do
                    body_drivers_orogen_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] https://gitlab.com/tidewise/drivers-gps_ublox/merge_requests/22
                    EOFBODY
                    pr_drivers_orogen_gps_ublox = add_pull_request(
                        "tidewise", "drivers-orogen-gps_ublox", 11,
                        body_drivers_orogen_gps_ublox
                    )

                    body_drivers_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] https://github.com/tidewise/base-cmake/pull/44
                    EOFBODY

                    pr_drivers_gps_ublox = autoproj_daemon_add_pull_request(
                        repo_url: "git@gitlab.com:tidewise/drivers-gps_ublox",
                        number: 22,
                        state: "open",
                        body: body_drivers_gps_ublox
                    )

                    pr_base_cmake = add_pull_request(
                        "tidewise", "base-cmake", 44,
                        nil
                    )

                    depends = retriever.retrieve_dependencies(pr_drivers_orogen_gps_ublox)
                    assert_equal [pr_drivers_gps_ublox, pr_base_cmake], depends
                end
                it "allows an exclamation mark in a PR ref" do
                    body_drivers_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] tidewise/drivers-orogen-gps_ublox!22
                    EOFBODY
                    pr_drivers_gps_ublox = autoproj_daemon_add_pull_request(
                        repo_url: "git@gitlab.com:tidewise/drivers-gps_ublox",
                        number: 11,
                        state: "open",
                        body: body_drivers_gps_ublox
                    )

                    pr_drivers_orogen_gps_ublox = autoproj_daemon_add_pull_request(
                        repo_url: "git@gitlab.com:tidewise/drivers-orogen-gps_ublox",
                        number: 22,
                        state: "open"
                    )
                    depends = retriever.retrieve_dependencies(pr_drivers_gps_ublox)
                    assert_equal [pr_drivers_orogen_gps_ublox], depends
                end
            end
        end
    end
end
