# frozen_string_literal: true

require "octokit"
require "autoproj/daemon/github/client"
require "test_helper"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Github API main module
        module Github
            describe Client do
                attr_reader :client

                before do
                    skip if ENV["AUTOPROJ_SKIP_GITHUB_API_TESTS"]
                    @client = Client.new(auto_paginate: false)
                end

                it "returns an array of pull requests" do
                    prs = client.pull_requests("rock-core", "buildconf", state: "closed")

                    assert_operator 0, :<, prs.size
                    prs.each { |pr| assert_equal PullRequest, pr.class }
                end

                it "returns an array of branches" do
                    branches = client.branches("rock-core", "buildconf")

                    assert_operator 0, :<, branches.size
                    branches.each { |branch| assert_equal Branch, branch.class }
                end

                it "retries on connection failure" do
                    runs = 0
                    flexmock(client).should_receive(:check_rate_limit_and_wait)
                    assert_raises Faraday::ConnectionFailed do
                        client.with_retry(1) do
                            runs += 1
                            raise Faraday::ConnectionFailed, "Connection failed"
                        end
                    end
                    assert_equal 2, runs
                end

                it "retries on rate limiting error" do
                    runs = 0
                    flexmock(client).should_receive(:check_rate_limit_and_wait)
                                    .times(5)
                    client.with_retry(1) do
                        runs += 1
                        raise Octokit::TooManyRequests.new, "rate limit" if runs < 5
                    end
                    assert_equal 5, runs
                end

                it "returns a human readable time" do
                    assert_equal "2h", client.humanize_time(2 * 60 * 60)
                    assert_equal "17m", client.humanize_time(17 * 60)
                    assert_equal "23s", client.humanize_time(23)
                    assert_equal "2h17m23s",
                                 client.humanize_time(2 * 60 * 60 + 17 * 60 + 23)
                end

                it "watis for the remaining time until next limit reset" do
                    rate_limit = flexmock
                    flexmock(Octokit::Client).new_instances
                                             .should_receive(:rate_limit)
                                             .and_return(rate_limit)

                    @client = Client.new
                    rate_limit.should_receive(:remaining).and_return(0)
                    rate_limit.should_receive(:resets_in).and_return(15)
                    flexmock(client).should_receive(:sleep).explicitly.with(16).once
                    client.check_rate_limit_and_wait
                end
            end
        end
    end
end
