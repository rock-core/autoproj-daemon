# frozen_string_literal: true

require "autoproj"
require "autoproj/ops/atomic_write"
require "autoproj/daemon/git_api/pull_request"
require "autoproj/daemon/git_api/url"
require "yaml"

module Autoproj
    # Main plugin module
    module Daemon
        # A PullRequest cache
        class PullRequestCache
            # @return [Array<CachedPullRequest>]
            attr_reader :pull_requests

            # @return [Autoproj::Workspace]
            attr_reader :ws

            def initialize(workspace)
                @pull_requests = []
                @ws = workspace
            end

            CachedPullRequest =
                Struct.new :repo_url, :number, :base_branch,
                           :head_sha, :updated_at, :overrides do
                    def caches_pull_request?(pull_request)
                        git_url == pull_request.git_url && number == pull_request.number
                    end

                    def git_url
                        GitAPI::URL.new(repo_url)
                    end
                end

            # @param [GitAPI::PullRequest] pull_request
            # @return [void]
            def delete(pull_request)
                pull_requests.delete_if { |pr| pr.caches_pull_request?(pull_request) }
            end

            # @param [GitAPI::PullRequest] pull_request
            # @return [CachedPullRequest]
            def add(pull_request, overrides)
                delete(pull_request)
                cached = CachedPullRequest.new(
                    pull_request.git_url.raw,
                    pull_request.number,
                    pull_request.base_branch,
                    pull_request.head_sha,
                    pull_request.updated_at,
                    overrides
                )
                pull_requests << cached
                cached
            end

            # @return [void]
            def clear
                @pull_requests = []
            end

            # @param [GitAPI::PullRequest] pull_request
            # @return [CachedPullRequest, nil]
            def cached(pull_request)
                pull_requests.find { |pr| pr.caches_pull_request?(pull_request) }
            end

            def include?(pull_request)
                cached(pull_request)
            end

            # @param [GitAPI::PullRequest] pull_request
            # @return [Boolean]
            def changed?(pull_request, overrides)
                found = cached(pull_request)
                return true unless found

                found.overrides != overrides ||
                    ((found.head_sha != pull_request.head_sha ||
                    found.base_branch != pull_request.base_branch) &&
                    pull_request.updated_at > found.updated_at)
            end

            CACHE_FILE = "pull_request_cache.yml"

            # @return [void]
            def dump
                Autoproj::Ops.atomic_write(cache_file) do |file|
                    file.write(pull_requests.to_yaml)
                end
            end

            # @return [String]
            def cache_file
                File.join(ws.dot_autoproj_dir, CACHE_FILE)
            end

            # @return [PullRequestCache]
            def reload
                unless File.exist?(cache_file)
                    @pull_requests = []
                    return self
                end
                @pull_requests =
                    YAML.safe_load(File.read(cache_file),
                                   [Symbol, CachedPullRequest, Time])
                self
            end

            # @param [Autoproj::Workspace] workspace
            # @return [PullRequestCache]
            def self.load(workspace)
                new(workspace).reload
            end
        end
    end
end
