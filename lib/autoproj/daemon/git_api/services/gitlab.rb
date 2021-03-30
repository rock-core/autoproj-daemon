# frozen_string_literal: true

require "gitlab"
require "pathname"
require "uri"
require "autoproj/daemon/git_api/branch"
require "autoproj/daemon/git_api/exceptions"
require "autoproj/daemon/git_api/pull_request"
require "autoproj/daemon/git_api/service"

module Autoproj
    module Daemon
        module GitAPI
            # :nodoc:
            module Services
                def self.gitlab(**options)
                    GitLab.new(**options)
                end

                # An abstraction layer for GitLab's REST API
                class GitLab < GitAPI::Service
                    def initialize(**options)
                        super
                        options = {
                            endpoint: api_endpoint,
                            private_token: options[:access_token]
                        }.compact

                        @client = Gitlab.client(**options)
                    end

                    # @param [GitAPI::URL] git_url
                    # @return [Array<PullRequest>]
                    def pull_requests(git_url, state: nil, base: nil)
                        options = {
                            state: state.to_s == "open" ? "opened" : state,
                            target_branch: base
                        }.compact

                        exception_adapter do
                            @client.merge_requests(
                                git_url.path, **options
                            ).auto_paginate.map do |mr|
                                PullRequest.from_ruby_hash(
                                    git_url, merge_request_to_ruby_hash(git_url, mr)
                                )
                            end
                        end
                    end

                    # @param [Gitlab::ObjectifiedHash] mrequest
                    # @return [Hash]
                    def merge_request_to_ruby_hash(git_url, mrequest)
                        state = mrequest.state == "opened" ? "open" : mrequest.state.to_s
                        {
                            state: state,
                            number: mrequest.iid,
                            title: mrequest.title,
                            updated_at: mrequest.updated_at,
                            body: mrequest.description,
                            html_url: mrequest.web_url,
                            draft: mrequest.work_in_progress,
                            user: {
                                login: mrequest.author.username
                            },
                            base: {
                                ref: mrequest.target_branch,
                                repo: {
                                    html_url: "https://#{git_url.full_path}"
                                }
                            },
                            head: {
                                ref: mrequest.source_branch,
                                sha: mrequest.sha,
                                user: {
                                    login: ""
                                }
                            }
                        }
                    end

                    # @param [Gitlab::ObjectifiedHash] branch
                    # @return [Hash]
                    def gitlab_branch_to_ruby_hash(git_url, branch)
                        {
                            repository_url: "https://#{git_url.full_path}",
                            name: branch.name,
                            commit: {
                                sha: branch.commit.id,
                                commit: {
                                    author: {
                                        name: branch.commit.committer_name,
                                        date: branch.commit.committed_date
                                    }
                                }
                            }
                        }
                    end

                    # @param [GitAPI::URL] git_url
                    # @return [Array<Branch>]
                    def branches(git_url)
                        exception_adapter do
                            @client.branches(git_url.path).auto_paginate.map do |branch|
                                Branch.from_ruby_hash(
                                    git_url, gitlab_branch_to_ruby_hash(git_url, branch)
                                )
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
                            model = gitlab_branch_to_ruby_hash(
                                git_url, @client.branch(git_url.path, branch_name)
                            )
                            Branch.from_ruby_hash(git_url, model)
                        end
                    end

                    # @return [RateLimit]
                    def rate_limit
                        # Not rate limited
                        RateLimit.new(1000, 0)
                    end

                    def exception_adapter
                        yield
                    rescue Gitlab::Error::NotFound => e
                        raise GitAPI::NotFound, e.message
                    rescue Errno::ECONNREFUSED => e
                        raise GitAPI::ConnectionFailed, e.message
                    rescue Net::ReadTimeout => e
                        raise GitAPI::ConnectionFailed, e.message
                    rescue EOFError => e
                        raise GitAPI::ConnectionFailed, e.message
                    rescue Errno::ECONNRESET => e
                        raise GitAPI::ConnectionFailed, e.message
                    rescue Errno::ECONNABORTED => e
                        raise GitAPI::ConnectionFailed, e.message
                    rescue Errno::EPIPE => e
                        raise GitAPI::ConnectionFailed, e.message
                    end

                    # @return [String]
                    def default_endpoint
                        "https://#{host}/api/v4"
                    end

                    # @param [String] ref
                    # @param [GitAPI::PullRequest] pull_request
                    # @return [Array]
                    def extract_info_from_short_ref(ref, pull_request)
                        return unless ref =~ /^!(\d+)$/

                        [pull_request.git_url.path, Regexp.last_match(1).to_i]
                    end

                    # @param [String] ref
                    # @param [GitAPI::PullRequest] pull_request
                    # @return [Array]
                    def extract_info_from_relative_ref(ref, pull_request)
                        return unless ref =~ /^([A-Za-z0-9\-_.]+)!(\d+)$/

                        path = "#{File.dirname(pull_request.git_url.path)}/"\
                               "#{Regexp.last_match(1)}"
                        number = Regexp.last_match(2).to_i
                        [path, number]
                    end

                    # @param [String] ref
                    # @return [Array]
                    def extract_info_from_full_ref(ref)
                        return unless ref =~ %r{^(([A-Za-z0-9\-_.]+/?)+)!(\d+)$}

                        path = Regexp.last_match(1)
                        path.chop! if path[-1] == "/"
                        number = Regexp.last_match(3).to_i
                        [path, number]
                    end

                    # @param [String] ref
                    # @return [Array]
                    def extract_info_from_url(ref)
                        begin
                            url = URL.new(ref)
                            return unless %w[http https].include?(url.uri.scheme)

                            path = url.path.split("/")
                            number = Integer(path.pop)
                            return unless path.pop == "merge_requests"

                            path.pop if path.last == "-"
                            path = path.join("/")
                        rescue StandardError
                            return nil
                        end
                        [path, number]
                    end

                    # @param [String] ref
                    # @param [GitAPI::PullRequest] pull_request
                    # @return [Array]
                    def extract_info_from_pull_request_ref(ref, pull_request)
                        path, number =
                            extract_info_from_short_ref(ref, pull_request) ||
                            extract_info_from_relative_ref(ref, pull_request) ||
                            extract_info_from_full_ref(ref) ||
                            extract_info_from_url(ref)

                        return unless path && number

                        ["https://#{host}/#{path}", number]
                    end
                end
            end
        end
    end
end
