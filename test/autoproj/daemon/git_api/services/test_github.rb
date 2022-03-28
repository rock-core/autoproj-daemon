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
                    ws.config.daemon_set_service("github.com", "apikey")
                    @client = Client.new(ws)
                end

                describe "live API tests" do
                    before do
                        skip unless ENV["GITHUB_API"]
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

                        it "returns the repository web url" do
                            branch = client.branch(url, "master")
                            assert_equal "https://github.com/rock-core/buildconf",
                                         branch.repository_url
                        end
                    end

                    describe "PULL_REQUEST_URL_RX" do
                        it "parses owner, name and number from PR url" do
                            owner, name, number =
                                Services::GitHub::PULL_REQUEST_URL_RX.match(
                                    "https://github.com////g-arjones._1//demo.pkg_1//pull//122"
                                )[1..-1]

                            assert_equal "g-arjones._1", owner
                            assert_equal "demo.pkg_1", name
                            assert_equal "122", number
                        end
                    end

                    describe "OWNER_NAME_AND_NUMBER_RX" do
                        it "parses owner, name and number from PR path" do
                            owner, name, number =
                                Services::GitHub::OWNER_NAME_AND_NUMBER_RX.match(
                                    "g-arjones._1/demo.pkg_1#122"
                                )[1..-1]

                            assert_equal "g-arjones._1", owner
                            assert_equal "demo.pkg_1", name
                            assert_equal "122", number
                        end
                    end

                    describe "NUMBER_RX" do
                        it "parses the PR number from relative PR path" do
                            number = Services::GitHub::NUMBER_RX.match("#122")[1]
                            assert_equal "122", number
                        end
                    end

                    describe "#extract_info_from_pull_request_ref" do
                        attr_reader :pr

                        before do
                            @pr = autoproj_daemon_create_pull_request(
                                repo_url: "git@github.com:g-arjones._1/demo.pkg_1.git",
                                number: 22
                            )
                        end

                        it "returns info when given a url" do
                            info = ["https://github.com/g-arjones._1/demo.pkg_1", 22]
                            assert_equal info, client.extract_info_from_pull_request_ref(
                                "https://github.com/g-arjones._1/demo.pkg_1/pull/22", pr
                            )
                        end
                        it "returns info when given a full path" do
                            info = ["https://github.com/g-arjones._1/demo.pkg_1", 22]
                            assert_equal info, client.extract_info_from_pull_request_ref(
                                "g-arjones._1/demo.pkg_1#22", pr
                            )
                        end
                        it "returns info when given a relative path" do
                            info = ["https://github.com/g-arjones._1/demo.pkg_1", 22]
                            assert_equal info, client.extract_info_from_pull_request_ref(
                                "#22", pr
                            )
                        end
                        it "returns nil when the item does not look like a PR ref" do
                            assert_nil client.extract_info_from_pull_request_ref(
                                "Feature", pr
                            )
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

                        it "returns the pull request body" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "Faced the same issue #80837 "\
                                "and didn't see much activity.\r\nThis PR fixes #80837 ",
                                         pull_request.body
                        end

                        it "returns the pull request url" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "https://github.com/microsoft/vscode/pull/81609",
                                         pull_request.web_url
                        end

                        it "returns the base repository url" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "https://github.com/microsoft/vscode",
                                         pull_request.repository_url
                        end

                        it "returns the pull request author" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "vedipen", pull_request.author
                        end

                        it "returns the last commit author" do
                            pull_request = client.pull_requests(url).first
                            assert_equal "vedipen", pull_request.last_committer
                        end

                        it "returns the draft status" do
                            pull_request = client.pull_requests(url).first
                            refute pull_request.draft?
                            assert_equal "refs/pull/81609/merge",
                                         client.test_branch_name(pull_request)

                            pr_model["draft"] = true
                            pull_request = PullRequest.new(URL.new(url), pr_model)
                            assert pull_request.draft?
                            assert_equal "refs/pull/81609/head",
                                         client.test_branch_name(pull_request)
                        end

                        it "returns the mergeable status" do
                            pull_request = client.pull_requests(url).first
                            assert pull_request.mergeable?
                            assert_equal "refs/pull/81609/merge",
                                         client.test_branch_name(pull_request)

                            pr_model["mergeable"] = false
                            pull_request = PullRequest.new(URL.new(url), pr_model)
                            refute pull_request.mergeable?
                            assert_equal "refs/pull/81609/head",
                                         client.test_branch_name(pull_request)
                        end
                    end
                end
            end
        end
    end
end
