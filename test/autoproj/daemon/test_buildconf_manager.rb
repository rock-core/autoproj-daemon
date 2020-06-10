# frozen_string_literal: true

require "test_helper"

# Autoproj main module
module Autoproj
    # Main daemon module
    module Daemon
        describe BuildconfManager do
            include Autoproj::Daemon::TestHelpers

            before do
                autoproj_daemon_mock_github_api
                autoproj_daemon_create_ws(
                    type: "git",
                    url: "git@github.com:rock-core/buildconf"
                )

                @packages = []
                @cache = PullRequestCache.new(@ws)
                @client = Github::Client.new

                @buildconf = PackageRepository.new(
                    "main configuration",
                    "rock-core",
                    "buildconf",
                    ws.manifest.main_package_set.vcs.to_hash,
                    buildconf: true,
                    ws: ws
                )

                @manager = BuildconfManager.new(
                    @buildconf, @client, @packages, @cache, @ws,
                    project: "myproject"
                )
            end

            def add_package(pkg_name, owner, name, vcs = {})
                package = PackageRepository.new(pkg_name, owner, name, vcs)
                @packages << package
            end
            describe "#update_pull_requests" do
                it "does not poll same repository twice" do
                    add_package("drivers/iodrivers_base2", "rock-core",
                                "drivers-iodrivers_base")
                    add_package("drivers/iodrivers_base", "rock-core",
                                "drivers-iodrivers_base")
                    add_package("drivers/gps_base2", "rock-core",
                                "drivers-gps_base")
                    add_package("drivers/gps_base", "rock-core",
                                "drivers-gps_base", branch: "devel")

                    flexmock(@client).should_receive(:pull_requests)
                                     .with(
                                         "rock-core",
                                         "drivers-gps_base",
                                         base: "master",
                                         state: "open"
                                     ).once.pass_thru

                    flexmock(@client).should_receive(:pull_requests)
                                     .with(
                                         "rock-core",
                                         "drivers-gps_base",
                                         base: "devel",
                                         state: "open"
                                     ).once.pass_thru

                    flexmock(@client).should_receive(:pull_requests)
                                     .with(
                                         "rock-core",
                                         "drivers-iodrivers_base",
                                         base: "master",
                                         state: "open"
                                     ).once.pass_thru

                    @manager.update_pull_requests
                end

                it "returns a flat and compact array of pull requests" do
                    add_package("drivers/iodrivers_base", "rock-core",
                                "drivers-iodrivers_base")

                    pr = autoproj_daemon_add_pull_request(base_owner: "rock-core",
                                                          base_name: "drivers-gps_base",
                                                          number: 1,
                                                          base_branch: "devel",
                                                          head_sha: "abcdef")

                    add_package("drivers/gps_base", "rock-core",
                                "drivers-gps_base", branch: "devel")

                    assert_equal [pr], @manager.update_pull_requests
                    assert_equal [pr], @manager.pull_requests
                end

                it "partitions stale pull requests" do
                    pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-gps_base",
                        number: 1,
                        updated_at: Time.new(1990, 1, 1),
                        base_branch: "devel",
                        head_sha: "abcdef"
                    )

                    add_package("drivers/gps_base", "rock-core",
                                "drivers-gps_base", branch: "devel")

                    assert_equal [], @manager.update_pull_requests
                    assert_equal [], @manager.pull_requests
                    assert_equal [pr], @manager.pull_requests_stale
                end
            end

            describe "#update_branches" do
                it "returns an array with the current branches" do
                    branches = []
                    branches << autoproj_daemon_add_branch(
                        "rock-core", "buildconf", branch_name: "master", sha: "abcdef"
                    )
                    branches << autoproj_daemon_add_branch(
                        "rock-core", "buildconf", branch_name: "devel", sha: "ghijkl"
                    )

                    assert_equal branches, @manager.update_branches
                    assert_equal branches, @manager.branches
                end
            end

            describe "#delete_stale_branches" do
                it "deletes branches that do not have a PR open" do
                    autoproj_daemon_add_branch(
                        "rock-core", "buildconf", branch_name: "master", sha: "abcdef"
                    )
                    stale = autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: "autoproj/myproject/rock-core/"\
                                     "drivers-iodrivers_base/pulls/12",
                        sha: "abcdef"
                    )
                    autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: "autoproj/myproject/rock-core/"\
                                     "drivers-gps_base/pulls/55",
                        sha: "ghijkl"
                    )

                    autoproj_daemon_add_pull_request(base_owner: "rock-core",
                                                     base_name: "drivers-gps_base",
                                                     number: 55,
                                                     base_branch: "master",
                                                     head_sha: "abcdef")

                    add_package("drivers/gps_base", "rock-core",
                                "drivers-gps_base", branch: "master")

                    autoproj_daemon_add_pull_request(base_owner: "rock-core",
                                                     base_name: "drivers-iodrivers_base",
                                                     number: 54,
                                                     base_branch: "master",
                                                     head_sha: "abcdef")

                    add_package("drivers/iodrivers_base", "rock-core",
                                "drivers-iodrivers_base", branch: "master")

                    @manager.update_branches
                    @manager.update_pull_requests

                    flexmock(@client).should_receive(:delete_branch).with(stale).once
                    @manager.delete_stale_branches
                end

                it "deletes branches that start with autoproj/ but do not match "\
                   "the expected pattern" do
                    stale = []
                    stale << autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: "autoproj/rock-core/"\
                                     "drivers-iodrivers_base/pulls/12",
                        sha: "abcdef"
                    )
                    stale << autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: "autoproj/something",
                        sha: "abcdef"
                    )
                    @manager.update_branches
                    @manager.update_pull_requests

                    flexmock(@client).should_receive(:delete_branch).with(stale[0]).once
                    flexmock(@client).should_receive(:delete_branch).with(stale[1]).once
                    @manager.delete_stale_branches
                end
            end

            describe "#create_missing_branches" do
                it "creates branches for open PRs" do
                    existing_branch = autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: "autoproj/myproject/rock-core/"\
                                     "drivers-iodrivers_base/pulls/17",
                        sha: "abcdef"
                    )

                    pr = autoproj_daemon_add_pull_request(base_owner: "rock-core",
                                                          base_name: "drivers-gps_base",
                                                          number: 55,
                                                          base_branch: "master",
                                                          head_sha: "abcdef")

                    add_package("drivers/gps_base", "rock-core",
                                "drivers-gps_base", branch: "master")

                    add_package("drivers/iodrivers_base", "rock-core",
                                "drivers-iodrivers_base", branch: "master")

                    autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 17,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )

                    @manager.update_branches
                    @manager.update_pull_requests

                    new_branch_name = "autoproj/myproject/"\
                                      "rock-core/drivers-gps_base/pulls/55"
                    new_branch = autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: new_branch_name,
                        sha: "abcdef"
                    )

                    flexmock(@manager).should_receive(:create_branch_for_pr)
                                      .with(new_branch_name, pr).once
                                      .and_return(new_branch)

                    created, existing = @manager.create_missing_branches
                    assert_equal [new_branch], created
                    assert_equal [existing_branch], existing
                end
            end
            describe "#trigger_build_if_branch_changed" do
                it "does not trigger if PR did not change" do
                    branch = autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: "autoproj/myproject/"\
                                     "rock-core/drivers-iodrivers_base/pulls/12",
                        sha: "abcdef"
                    )

                    pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 12,
                        base_branch: "master",
                        head_owner: "g-arjones",
                        head_name: "drivers-iodrivers_base_fork",
                        head_branch: "add_feature",
                        head_sha: "abcdef"
                    )

                    add_package("iodrivers_base", "rock-core", "drivers-iodrivers_base")
                    add_package("drivers/iodrivers_base", "rock-core",
                                "drivers-iodrivers_base", branch: "master")

                    overrides = []
                    overrides << {
                        "iodrivers_base" => {
                            "remote_branch" => "refs/pull/12/merge"
                        }
                    }
                    overrides << {
                        "drivers/iodrivers_base" => {
                            "remote_branch" => "refs/pull/12/merge"
                        }
                    }

                    @cache.add(pr, overrides)
                    @manager.update_branches
                    @manager.update_pull_requests

                    flexmock(@manager).should_receive(:commit_and_push_overrides).never
                    flexmock(@manager.bb).should_receive(:build).never
                    @manager.trigger_build_if_branch_changed([branch])
                end
                it "triggers if overrides changed" do
                    branch = autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: "autoproj/myproject/"\
                                     "rock-core/drivers-iodrivers_base/pulls/12",
                        sha: "abcdef"
                    )

                    pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 12,
                        base_branch: "master",
                        head_owner: "g-arjones",
                        head_name: "iodrivers_base_fork",
                        head_branch: "add_feature",
                        head_sha: "abcdef"
                    )

                    add_package("drivers/iodrivers_base", "rock-core",
                                "drivers-iodrivers_base", branch: "master")

                    overrides = []

                    @cache.add(pr, overrides)
                    @manager.update_branches
                    @manager.update_pull_requests

                    branch_name = "autoproj/myproject/"\
                                  "rock-core/drivers-iodrivers_base/pulls/12"
                    expected_overrides = [{
                        "drivers/iodrivers_base" => {
                            "remote_branch" => "refs/pull/12/merge"
                        }
                    }]

                    flexmock(@manager).should_receive(:commit_and_push_overrides)
                                      .with(branch_name, expected_overrides).once
                    flexmock(@manager.bb).should_receive(:build_pull_request)
                                         .with(pr).once

                    @manager.trigger_build_if_branch_changed([branch])
                end
                it "triggers if PR head sha changed" do
                    branch = autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: "autoproj/myproject/"\
                                     "rock-core/drivers-iodrivers_base/pulls/12",
                        sha: "abcdef"
                    )

                    pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 12,
                        base_branch: "master",
                        head_owner: "g-arjones",
                        head_name: "iodrivers_base_fork",
                        head_branch: "add_feature",
                        head_sha: "abcdef"
                    )

                    add_package("drivers/iodrivers_base", "rock-core",
                                "drivers-iodrivers_base", branch: "master")

                    overrides = []
                    overrides << {
                        "drivers/iodrivers_base" => {
                            "remote_branch" => "refs/pull/12/merge"
                        }
                    }

                    pr_cached = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 12,
                        base_branch: "master",
                        head_owner: "g-arjones",
                        head_name: "iodrivers_base_fork",
                        head_branch: "add_feature",
                        head_sha: "efghij",
                        updated_at: Time.now - 2
                    )

                    @cache.add(pr_cached, overrides)
                    @manager.update_branches
                    @manager.update_pull_requests
                    branch_name = "autoproj/myproject/"\
                                  "rock-core/drivers-iodrivers_base/pulls/12"

                    flexmock(@manager.bb).should_receive(:build_pull_request)
                                         .with(pr).once
                    flexmock(@manager).should_receive(:commit_and_push_overrides)
                                      .with(branch_name, overrides).once

                    @manager.trigger_build_if_branch_changed([branch])
                end
                it "triggers if PR base branch changed" do
                    branch = autoproj_daemon_add_branch(
                        "rock-core", "buildconf",
                        branch_name: "autoproj/myproject/"\
                                     "rock-core/drivers-iodrivers_base/pulls/12",
                        sha: "abcdef"
                    )

                    pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 12,
                        base_branch: "master",
                        head_owner: "g-arjones",
                        head_name: "iodrivers_base_fork",
                        head_branch: "add_feature",
                        head_sha: "abcdef"
                    )

                    add_package("drivers/iodrivers_base", "rock-core",
                                "drivers-iodrivers_base", branch: "master")

                    overrides = []
                    overrides << {
                        "drivers/iodrivers_base" => {
                            "remote_branch" => "refs/pull/12/merge"
                        }
                    }

                    pr_cached = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 12,
                        base_branch: "develop",
                        head_owner: "g-arjones",
                        head_name: "iodrivers_base_fork",
                        head_branch: "add_feature",
                        head_sha: "abcdef",
                        updated_at: Time.now - 2
                    )

                    @cache.add(pr_cached, overrides)
                    @manager.update_branches
                    @manager.update_pull_requests

                    branch_name = "autoproj/myproject/"\
                                  "rock-core/drivers-iodrivers_base/pulls/12"
                    flexmock(@manager.bb).should_receive(:build_pull_request)
                                         .with(pr).once
                    flexmock(@manager).should_receive(:commit_and_push_overrides)
                                      .with(branch_name, overrides).once

                    @manager.trigger_build_if_branch_changed([branch])
                end
            end

            describe "#update_cache" do
                it "removes pull requests that are no longer tracked" do
                    one = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 12,
                        base_branch: "develop",
                        head_owner: "g-arjones",
                        head_name: "drivers-iodrivers_base",
                        head_branch: "add_feature",
                        head_sha: "abcdef"
                    )

                    two = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 14,
                        base_branch: "develop",
                        head_owner: "g-arjones",
                        head_name: "drivers-iodrivers_base",
                        head_branch: "other_feature",
                        head_sha: "ghijkl"
                    )

                    three = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 16,
                        base_branch: "develop",
                        head_owner: "g-arjones",
                        head_name: "drivers-iodrivers_base",
                        head_branch: "awesome_feature",
                        head_sha: "abcdef"
                    )

                    @manager.cache.add(one, [])
                    @manager.cache.add(two, [])
                    @manager.cache.add(three, [])
                    @manager.pull_requests << three

                    assert_equal 3, @manager.cache.pull_requests.size

                    @manager.update_cache
                    @manager.cache.reload

                    assert_equal 1, @manager.cache.pull_requests.size
                    refute_nil @manager.cache.cached(three)
                end
                it "keeps stale pull requests in the cache" do
                    pr = autoproj_daemon_add_pull_request(
                        base_owner: "rock-core",
                        base_name: "drivers-iodrivers_base",
                        number: 12,
                        base_branch: "develop",
                        head_owner: "g-arjones",
                        head_name: "drivers-iodrivers_base",
                        head_branch: "add_feature",
                        updated_at: Time.new(1990, 1, 1),
                        head_sha: "abcdef"
                    )

                    @manager.cache.add(pr, [])
                    @manager.pull_requests_stale << pr

                    @manager.update_cache
                    @manager.cache.reload

                    assert_equal 1, @manager.cache.pull_requests.size
                    refute_nil @manager.cache.cached(pr)
                end
            end
        end
    end
end
