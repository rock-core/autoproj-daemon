# frozen_string_literal: true

require "autoproj/daemon/git_api/client"
require "test_helper"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Github API main module
        module GitAPI
            describe Client do
                include Autoproj::Daemon::TestHelpers
                attr_reader :client

                before do
                    autoproj_daemon_create_ws(
                        type: "git",
                        url: "git@github.com:rock-core/buildconf"
                    )
                    @client = Client.new(ws)
                end

                describe "live API tests" do
                    before do
                        skip if ENV["AUTOPROJ_SKIP_LIVE_API_TESTS"]
                    end

                    it "returns an array of pull requests" do
                        prs = client.pull_requests(
                            "git@github.com:rock-core/buildconf", state: "closed"
                        )

                        assert_operator 0, :<, prs.size
                        prs.each { |pr| assert_equal PullRequest, pr.class }
                    end

                    it "returns an array of branches" do
                        branches = client.branches("git@github.com:rock-core/buildconf")

                        assert_operator 0, :<, branches.size
                        branches.each { |branch| assert_equal Branch, branch.class }
                    end

                    it "returns a branch" do
                        branch = client.branch(
                            "git@github.com:rock-core/buildconf", "master"
                        )
                        assert_equal Branch, branch.class
                    end
                end

                describe "mock API tests" do
                    attr_reader :octomock, :url, :branch_model, :pr_model

                    let(:client) { Client.new(ws) }
                    before do
                        @url = "git@github.com:rock-core/buildconf"
                        @octomock = flexmock(Octokit::Client).new_instances
                        @octomock.should_receive(:rate_limit)
                                 .and_return(Service::RateLimit.new(1, 0))
                    end

                    def assert_transforms(from, to, *args)
                        assert_raises(to) do
                            client.service(url).exception_adapter { raise from, *args }
                        end
                    end

                    it "transforms exceptions" do
                        assert_transforms(Octokit::TooManyRequests,
                                          GitAPI::TooManyRequests, {})

                        assert_transforms(Octokit::NotFound, GitAPI::NotFound, {})
                        assert_transforms(Faraday::ConnectionFailed,
                                          GitAPI::ConnectionFailed, {})
                    end

                    describe "branch data" do
                        before do
                            @branch_model = JSON.parse(
                                File.read(File.expand_path("github_branch.json", __dir__))
                            )
                            octomock.should_receive(:branch)
                                    .with("rock-core/buildconf", "master")
                                    .and_return(branch_model)

                            octomock.should_receive(:branches)
                                    .with("rock-core/buildconf")
                                    .and_return([branch_model])
                        end

                        it "stores repo url" do
                            branch = client.branch(url, "master")
                            assert branch.git_url.same?(url)
                        end

                        it "returns branch name" do
                            branch = client.branch(url, "master")
                            assert_equal "1.11", branch.branch_name
                        end

                        it "returns sha" do
                            branch = client.branch(url, "master")
                            assert_equal "8076a19fdcab7e1fc1707952d652f0bb6c6db331",
                                         branch.sha
                        end

                        it "returns the commit author" do
                            branch = client.branch(url, "master")
                            assert_equal "The Octocat", branch.commit_author
                        end

                        it "returns the commit date" do
                            branch = client.branch(url, "master")
                            assert_equal Time.parse("2012-03-06T15:06:50-08:00"),
                                         branch.commit_date
                        end

                        it "returns an array of branches" do
                            branches = client.branches(url)
                            assert_equal 1, branches.size
                            assert_equal Branch, branches.first.class
                        end
                    end

                    describe "pull request data" do
                        before do
                            @pr_model = JSON.parse(
                                File.read(
                                    File.expand_path("github_pull_request.json", __dir__)
                                )
                            )
                            octomock.should_receive(:pull_requests)
                                    .with("rock-core/buildconf", base: nil, state: nil)
                                    .and_return([pr_model])
                        end

                        it "stores repo url" do
                            pull_request = client.pull_requests(url).first
                            assert pull_request.git_url.same?(url)
                        end

                        it "returns true if open" do
                            pull_request = client.pull_requests(url).first
                            assert pull_request.open?
                        end

                        it "returns false if closed" do
                            pr_model["state"] = "closed"
                            pull_request = PullRequest.new(URL.new(url), pr_model)
                            refute pull_request.open?
                        end

                        it "returns the number" do
                            pull_request = client.pull_requests(url).first
                            assert_equal 81_609, pull_request.number
                        end

                        it "returns the title" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "Save all and commit fix", pull_request.title
                        end

                        it "returns the base branch" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "master", pull_request.base_branch
                        end

                        it "returns the head branch" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "saveAllAndCommitFix", pull_request.head_branch
                        end

                        it "returns the head sha" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "6a0c40a0cc4edd4b5c9e520be86ac0c5c4402dd9",
                                         pull_request.head_sha
                        end

                        it "returns the base owner" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "microsoft", pull_request.base_owner
                        end

                        it "returns the head owner" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "vedipen", pull_request.head_owner
                        end

                        it "returns the base repo name" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "vscode", pull_request.base_name
                        end

                        it "returns the head repo name" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "vscode", pull_request.head_name
                        end

                        it "returns nil if head repo is nil" do
                            pull_request = client.pull_requests(url).first
                            @model = pull_request.instance_variable_get(:@model)
                            @model["head"]["repo"] = nil
                            assert_nil pull_request.head_name
                        end

                        it "returns the pull request body" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "Faced the same issue #80837 "\
                                "and didn't see much activity.\r\nThis PR fixes #80837 ",
                                         pull_request.body
                        end
                    end
                end
            end
        end
    end
end
