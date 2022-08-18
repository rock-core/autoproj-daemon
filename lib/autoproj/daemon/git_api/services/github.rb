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

                    # @return [Symbol] "auto", the merge commit used in the CI
                    #   build will be the GitHub-generated merge commit if
                    #   available, and the HEAD of the pull request's branch
                    #   otherwise. If "merge", it is always the merge commit
                    #   unless the pull request is a draft.  If "head", it is
                    #   always the pull request's branch's HEAD.
                    attr_accessor :pr_commit_strategy

                    # @param [Number] mergeability_timeout how long, in seconds,
                    #   we wait for GitHub to compute a pull request's mergeability
                    # @param [Symbol] pr_commit_strategy If "auto", the merge
                    #   commit used in the CI build will be the GitHub-generated
                    #   merge commit if available, and the HEAD of the pull
                    #   request's branch otherwise. If "merge", it is always
                    #   the merge commit unless the pull request is a draft.
                    #   If "head", it is always the pull request's branch's
                    #   HEAD.
                    def initialize(
                        pr_commit_strategy: "auto", mergeability_timeout: 60,
                        **options
                    )
                        super(**options)

                        @client = create_octokit_client(cache: true)
                        @client_nocache = create_octokit_client(cache: false)

                        @pr_commit_strategy = pr_commit_strategy
                        @mergeability_timeout = mergeability_timeout
                        @mergeability_cache = {}
                    end

                    # @api private
                    #
                    # Create an octokit client
                    def create_octokit_client(cache: true, **options)
                        stack = Faraday::RackBuilder.new do |builder|
                            if cache
                                builder.use Faraday::HttpCache, serializer: Marshal,
                                                                shared_cache: false
                            end

                            builder.use Octokit::Middleware::FollowRedirects
                            builder.use Octokit::Response::RaiseError
                            builder.adapter Faraday.default_adapter
                        end
                        client = Octokit::Client.new(middleware: stack, **options)
                        client.auto_paginate = true
                        client
                    end

                    # @param [GitAPI::URL] git_url
                    # @return [Array<PullRequest>]
                    def pull_requests(git_url, **options)
                        exception_adapter do
                            @client.pull_requests(git_url.path, **options).map do |pr|
                                mergeable = pull_request_mergeable?(git_url, pr)
                                pr = pr.to_hash.merge({ "mergeable" => mergeable })
                                PullRequest.from_ruby_hash(git_url, pr)
                            end
                        end
                    ensure
                        pull_request_mergeable_cache_clean
                    end

                    # Check if a pull request is mergeable
                    #
                    # @param [GitAPI::URL] repo_url the repository URL
                    # @param [Sawyer::Response] pr the pull request description as
                    #   returned GitHub's list endpoint
                    def pull_request_mergeable?(
                        repo_url, pull_request, poll: 0.1, timeout: @mergeability_timeout
                    )
                        from_cache =
                            pull_request_mergeable_cache_get(repo_url, pull_request)
                        return from_cache unless from_cache.nil?

                        result = pull_request_query_mergeable(
                            repo_url, pull_request["number"], poll: poll, timeout: timeout
                        )
                        pull_request_mergeable_cache_set(repo_url, pull_request, result)
                        result
                    end

                    # @api private
                    #
                    # Explicitly query a pull request mergeability, waiting for
                    # GitHub to compute it
                    #
                    # @param [GitAPI::URL] repo_url the repository URL
                    # @param [Integer] number the pull request number
                    def pull_request_query_mergeable(
                        repo_url, number, poll: 0.1, timeout: @mergeability_timeout
                    )
                        deadline = Time.now + timeout
                        while Time.now < deadline
                            exception_adapter do
                                info = @client_nocache.pull_request(repo_url.path, number)
                                mergeable = info["mergeable"]
                                return mergeable unless mergeable.nil?

                                Autoproj.message(
                                    "waiting for GitHub to compute mergeability "\
                                    "for #{repo_url.path}##{number}"
                                )
                                sleep(poll)
                            end
                        end

                        Autoproj.warn(
                            "timed out waiting for for GitHub to compute mergeability "\
                            "for #{repo_url.path}##{number}, acting as if it is not "\
                            "mergeable"
                        )
                        nil
                    end

                    def pull_request_mergeable_cache_key(git_url, pull_request)
                        [git_url, pull_request["number"], pull_request["base"]["sha"],
                         pull_request["head"]["sha"]]
                    end

                    def pull_request_mergeable_cache_get(git_url, pull_request)
                        key = pull_request_mergeable_cache_key(git_url, pull_request)
                        return unless (entry = @mergeability_cache[key])

                        entry[1] = Time.now
                        entry[0]
                    end

                    def pull_request_mergeable_cache_set(git_url, pull_request, result)
                        key = pull_request_mergeable_cache_key(git_url, pull_request)
                        @mergeability_cache[key] = [result, Time.now]
                    end

                    def pull_request_mergeable_cache_clean(lifetime = 3600 * 24 * 7)
                        earliest = Time.now - lifetime
                        @mergeability_cache.delete_if do |_, (_, last_access)|
                            last_access < earliest
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
                        head =
                            if pull_request.draft?
                                "head"
                            elsif @pr_commit_strategy == "merge"
                                "merge"
                            elsif @pr_commit_strategy == "head"
                                "head"
                            elsif pull_request.mergeable?
                                "merge"
                            else
                                "head"
                            end

                        "refs/pull/#{pull_request.number}/#{head}"
                    end
                end
            end
        end
    end
end
