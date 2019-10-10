# frozen_string_literal: true

require 'autoproj/daemon/github/client'

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Github API main module
        module Github
            describe Client do
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
            end
        end
    end
end
