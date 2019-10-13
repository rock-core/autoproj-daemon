# frozen_string_literal: true

require 'json'
require 'octokit'
require 'autoproj/daemon/github/branch'
require 'autoproj/daemon/github/pull_request'
require 'autoproj/daemon/github/push_event'
require 'autoproj/daemon/github/pull_request_event'

module Autoproj
    module Daemon
        module Github
            # An abstraction layer for GitHub's REST API
            class Client
                def initialize(options = {})
                    @client = Octokit::Client.new(access_token: options[:access_token])
                    @client.auto_paginate = options[:auto_paginate]
                end

                # @return [Array<PullRequest>]
                def pull_requests(owner, name, options = {})
                    @client.pull_requests("#{owner}/#{name}", options).map do |pr|
                        PullRequest.new(pr.to_hash)
                    end
                end

                # @return [Array<PushEvent, PullRequestEvent>]
                def fetch_events(owner)
                    @client.user_events(owner).map do |event|
                        type = event['type']
                        next unless %w[PullRequestEvent PushEvent].include? type

                        if type == 'PullRequestEvent'
                            PullRequestEvent.new(event.to_hash)
                        else
                            PushEvent.new(event.to_hash)
                        end
                    end.compact
                end

                # @return [Array<Branch>]
                def branches(owner, name, options = {})
                    @client.branches("#{owner}/#{name}", options).map do |branch|
                        Branch.new(owner, name, branch.to_hash)
                    end
                end

                # @param [Branch] branch A branch to delete
                def delete_branch(branch)
                    @client.delete_branch(
                        "#{branch.owner}/#{branch.name}", branch.branch_name
                    )
                end

                # @param [String] owner
                # @param [String] name
                # @param [String] branch_name
                def branch(owner, name, branch_name)
                    model = @client.branch(
                        "#{owner}/#{name}", branch_name
                    ).to_hash
                    Branch.new(owner, name, model)
                end

                # @return [Integer]
                def rate_limit_remaining
                    @client.rate_limit.remaining
                end

                # @return [Time]
                def last_response_time
                    @client.last_response.headers[:time]
                end
            end
        end
    end
end
