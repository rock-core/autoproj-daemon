# frozen_string_literal: true

require 'json'
require 'octokit'
require 'autoproj/daemon/github/branch'
require 'autoproj/daemon/github/pull_request'

module Autoproj
    module Daemon
        module Github
            # An abstraction layer for GitHub's REST API
            class Client
                def initialize(options = {})
                    @client = Octokit::Client.new(api_key: options[:api_key])
                    @client.auto_paginate = options[:auto_paginate]
                end

                # @return [Array<PullRequest>]
                def pull_requests(owner, name, options = {})
                    @client.pull_requests("#{owner}/#{name}", options).map do |pr|
                        PullRequest.new(pr.to_hash.to_json)
                    end
                end

                # @return [Array<Branch>]
                def branches(owner, name, options = {})
                    @client.branches("#{owner}/#{name}", options).map do |branch|
                        Branch.new(owner, name, branch.to_hash.to_json)
                    end
                end

                # @param [Autoproj::Github::Branch] branch A branch to delete
                def delete_branch(branch)
                    @client.delete_branch(
                        "#{branch.owner}/#{branch.name}", branch.branch_name
                    )
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
