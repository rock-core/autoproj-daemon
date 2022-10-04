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
                           :head_sha, :draft?, :updated_at, :dependencies do
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
            def add(pull_request)
                delete(pull_request)
                cached = CachedPullRequest.new(
                    pull_request.git_url.raw,
                    pull_request.number,
                    pull_request.base_branch,
                    pull_request.head_sha,
                    pull_request.draft?,
                    pull_request.updated_at,
                    dependencies(pull_request)
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
            # @return [Array<Hash>]
            def dependencies(pull_request)
                return [] unless pull_request.dependencies

                pull_request.recursive_dependencies.map do |pr|
                    {
                        "repository" => pr.git_url.full_path,
                        "number" => pr.number,
                        "base_branch" => pr.base_branch,
                        "head" => pr.head_sha,
                        "draft" => pr.draft?
                    }
                end
            end

            # @param [GitAPI::PullRequest] pull_request
            # @return [Boolean]
            def changed?(pull_request)
                found = cached(pull_request)
                return true unless found

                found.dependencies.to_set != dependencies(pull_request).to_set ||
                    ((found.head_sha != pull_request.head_sha ||
                    found.base_branch != pull_request.base_branch ||
                    found.draft? != pull_request.draft?) &&
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

                # Initialize dependencies in case the cache file still uses the
                # old format that had overrides instead. This will cause all non-stale
                # PRs to be rebuilt.
                @pull_requests.each { |pr| pr.dependencies ||= [] }

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
