# frozen_string_literal: true

require "json"
require "octokit"
require "autoproj"
require "autoproj/daemon/github/branch"
require "autoproj/daemon/github/pull_request"

module Autoproj
    module Daemon
        module Github
            # An abstraction layer for GitHub's REST API
            class Client
                def initialize(options = {})
                    @client = Octokit::Client.new(access_token: options[:access_token])
                    @client.auto_paginate = options[:auto_paginate]
                end

                # @return [String]
                def humanize_time(secs)
                    [[60, :s], [60, :m], [24, :h]].map do |count, name|
                        if secs > 0
                            secs, n = secs.divmod(count)
                            "#{n.to_i}#{name}" unless n.to_i == 0
                        end
                    end.compact.reverse.join("")
                end

                # @return [void]
                def check_rate_limit_and_wait
                    return if @client.rate_limit.remaining > 0

                    wait_for = @client.rate_limit.resets_in + 1
                    Autoproj.message "API calls rate limit exceeded, waiting for "\
                                     "#{humanize_time(wait_for)}"
                    sleep wait_for
                end

                # @return [void]
                def with_retry(times = 5)
                    retries ||= 0
                    check_rate_limit_and_wait
                    yield
                rescue Faraday::ConnectionFailed
                    retries += 1
                    if retries <= times
                        sleep 1
                        retry
                    end
                    raise
                rescue Octokit::TooManyRequests
                    retry
                end

                # @return [Array<PullRequest>]
                def pull_requests(owner, name, options = {})
                    with_retry do
                        @client.pull_requests("#{owner}/#{name}", options).map do |pr|
                            PullRequest.from_ruby_hash(pr.to_hash)
                        end
                    end
                end

                # @return [PullRequest]
                def pull_request(owner, name, number, options = {})
                    with_retry do
                        PullRequest.from_ruby_hash(
                            @client.pull_request(
                                "#{owner}/#{name}", number, options
                            ).to_hash
                        )
                    end
                rescue Octokit::NotFound
                    nil
                end

                # @return [Array<Branch>]
                def branches(owner, name, options = {})
                    with_retry do
                        @client.branches("#{owner}/#{name}", options).map do |branch|
                            Branch.from_ruby_hash(owner, name, branch.to_hash)
                        end
                    end
                end

                # @param [Branch] branch A branch to delete
                # @return [void]
                def delete_branch(branch)
                    with_retry do
                        @client.delete_branch(
                            "#{branch.owner}/#{branch.name}", branch.branch_name
                        )
                    end
                end

                # @param [String] owner
                # @param [String] name
                # @param [String] branch_name
                # @return [void]
                def delete_branch_by_name(owner, name, branch_name)
                    with_retry do
                        @client.delete_branch(
                            "#{owner}/#{name}", branch_name
                        )
                    end
                end

                # @param [String] owner
                # @param [String] name
                # @param [String] branch_name
                def branch(owner, name, branch_name)
                    model = with_retry do
                        @client.branch(
                            "#{owner}/#{name}", branch_name
                        ).to_hash
                    end
                    Branch.from_ruby_hash(owner, name, model)
                end

                # @return [Integer]
                def rate_limit_remaining
                    with_retry do
                        @client.rate_limit!.remaining
                    end
                end

                # @return [Time]
                def last_response_time
                    @client.last_response.headers[:time]
                end
            end
        end
    end
end
