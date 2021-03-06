# frozen_string_literal: true

require "json"
require "octokit"
require "autoproj"
require "faraday-http-cache"
require "autoproj/daemon/git_api/branch"
require "autoproj/daemon/git_api/exceptions"
require "autoproj/daemon/git_api/pull_request"
require "autoproj/daemon/git_api/service"

module Autoproj
    module Daemon
        module GitAPI
            # :nodoc:
            module Services
                def self.github(**options)
                    GitHub.new(**options)
                end

                # An abstraction layer for GitHub's REST API
                class GitHub < GitAPI::Service
                    PULL_REQUEST_URL_RX =
                        %r{https?://(?:\w+\.)?github.com(?:/+)
                        ([A-Za-z\d+_\-.]+)(?:/+)([A-Za-z\d+_\-.]+)(?:/+)pull(?:/+)(\d+)}x
                        .freeze

                    OWNER_NAME_AND_NUMBER_RX = %r{([A-Za-z\d+_\-.]+)/
                        ([A-Za-z\d+_\-.]+)\#(\d+)}x.freeze

                    NUMBER_RX = /\#(\d+)/.freeze

                    def initialize(**options)
                        super

                        stack = Faraday::RackBuilder.new do |builder|
                            builder.use Faraday::HttpCache, serializer: Marshal,
                                                            shared_cache: false

                            builder.use Octokit::Middleware::FollowRedirects
                            builder.use Octokit::Response::RaiseError
                            builder.adapter Faraday.default_adapter
                        end

                        options.merge!(middleware: stack).compact!

                        @client = Octokit::Client.new(**options)
                        @client.auto_paginate = true
                    end

                    # @param [GitAPI::URL] git_url
                    # @return [Array<PullRequest>]
                    def pull_requests(git_url, **options)
                        exception_adapter do
                            @client.pull_requests(git_url.path, **options).map do |pr|
                                PullRequest.from_ruby_hash(git_url, pr.to_hash)
                            end
                        end
                    end

                    # @param [GitAPI::URL] git_url
                    # @return [Array<Branch>]
                    def branches(git_url)
                        exception_adapter do
                            @client.branches(git_url.path).map do |branch|
                                branch = branch.to_hash
                                branch["repository_url"] = "https://#{git_url.full_path}"
                                Branch.from_ruby_hash(git_url, branch)
                            end
                        end
                    end

                    # @param [Branch] branch A branch to delete
                    # @return [void]
                    def delete_branch(branch)
                        exception_adapter do
                            @client.delete_branch(branch.git_url.path, branch.branch_name)
                        end
                    end

                    # @param [GitAPI::URL] git_url
                    # @param [String] branch_name
                    # @return [void]
                    def delete_branch_by_name(git_url, branch_name)
                        exception_adapter do
                            @client.delete_branch(git_url.path, branch_name)
                        end
                    end

                    # @param [GitAPI::URL] git_url
                    # @param [String] branch_name
                    # @return [Branch]
                    def branch(git_url, branch_name)
                        exception_adapter do
                            model = @client.branch(git_url.path, branch_name).to_hash
                            model["repository_url"] = "https://#{git_url.full_path}"
                            Branch.from_ruby_hash(git_url, model)
                        end
                    end

                    # @return [RateLimit]
                    def rate_limit
                        exception_adapter do
                            RateLimit.new(
                                @client.rate_limit.remaining,
                                @client.rate_limit.resets_in
                            )
                        end
                    end

                    # @return [Array]
                    def extract_info_from_pull_request_ref(ref, pull_request)
                        if (match = PULL_REQUEST_URL_RX.match(ref))
                            owner, name, number = match[1..-1]
                        elsif (match = OWNER_NAME_AND_NUMBER_RX.match(ref))
                            owner, name, number = match[1..-1]
                        elsif (match = NUMBER_RX.match(ref))
                            owner, name = pull_request.git_url.path.split("/")
                            number = match[1]
                        else
                            return nil
                        end

                        number = number.to_i
                        ["https://github.com/#{owner}/#{name}", number]
                    end

                    def exception_adapter
                        yield
                    rescue Octokit::NotFound => e
                        raise GitAPI::NotFound, e.message
                    rescue Faraday::ConnectionFailed => e
                        raise GitAPI::ConnectionFailed, e.message
                    rescue Octokit::TooManyRequests => e
                        raise GitAPI::TooManyRequests, e.message
                    end

                    # @param [GitAPI::PullRequest] pull_request
                    # @return [String]
                    def test_branch_name(pull_request)
                        head = if pull_request.draft? || !pull_request.mergeable?
                                   "head"
                               else
                                   "merge"
                               end

                        "refs/pull/#{pull_request.number}/#{head}"
                    end
                end
            end
        end
    end
end
