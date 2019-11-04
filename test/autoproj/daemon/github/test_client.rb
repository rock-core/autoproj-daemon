# frozen_string_literal: true

require 'octokit'
require 'autoproj/daemon/github/client'

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Github API main module
        module Github
            describe Client do # rubocop: disable Metrics/BlockLength
                attr_reader :client
                before do
                    skip if ENV['AUTOPROJ_SKIP_GITHUB_API_TESTS']
                    @client = Client.new(auto_paginate: false)
                end

                it 'returns an array of pull requests' do
                    prs = client.pull_requests('rock-core', 'buildconf', state: 'closed')

                    assert_operator 0, :<, prs.size
                    prs.each { |pr| assert_equal PullRequest, pr.class }
                end

                it 'returns an array of branches' do
                    branches = client.branches('rock-core', 'buildconf')

                    assert_operator 0, :<, branches.size
                    branches.each { |branch| assert_equal Branch, branch.class }
                end

                it 'returns github last reponse time' do
                    client.rate_limit_remaining
                    assert Time, client.last_response_time.class
                end

                it 'returns a compact Array of events' do
                    events = [
                        { 'type' => 'PushEvent' },
                        { 'type' => 'PullRequestEvent' },
                        { 'type' => 'CreateEvent' }
                    ]

                    flexmock(Octokit::Client).new_instances.should_receive(:user_events)
                                             .with('rock-core').and_return(events)

                    @client = Client.new(auto_paginate: false)
                    fetched_events = client.fetch_events('rock-core')
                    assert_equal 2, fetched_events.size
                    assert_kind_of PushEvent, fetched_events.first
                    assert_kind_of PullRequestEvent, fetched_events.last
                end

                it 'retries on connection failure' do
                    runs = 0
                    assert_raises Faraday::ConnectionFailed do
                        client.with_retry(1) do
                            runs += 1
                            raise Faraday::ConnectionFailed, 'Connection failed'
                        end
                    end
                    assert_equal 2, runs
                end
            end
        end
    end
end
