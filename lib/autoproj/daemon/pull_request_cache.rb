# frozen_string_literal: true

require 'autoproj'
require 'autoproj/daemon/github/pull_request'
require 'yaml'

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

            CachedPullRequest = Struct.new :base_owner, :base_name,
                                           :number, :base_branch, :head_sha, :overrides

            # @param [CachedPullRequest] cache
            # @param [Github::PullRequest] pull_request
            # @return [Boolean]
            def same?(cache, pull_request)
                cache.base_owner == pull_request.base_owner &&
                    cache.base_name == pull_request.base_name &&
                    cache.number == pull_request.number
            end

            # @param [Github::PullRequest] pull_request
            # @return [void]
            def add(pull_request, overrides)
                pull_requests.delete_if { |pr| same?(pr, pull_request) }
                pull_requests << CachedPullRequest.new(
                    pull_request.base_owner,
                    pull_request.base_name,
                    pull_request.number,
                    pull_request.base_branch,
                    pull_request.head_sha,
                    overrides
                )
            end

            # @return [void]
            def clear
                @pull_requests = []
            end

            # @param [Github::PullRequest] pull_request
            # @return [Boolean]
            def changed?(pull_request, overrides)
                found = pull_requests.find { |pr| same?(pr, pull_request) }
                return true unless found

                found.overrides != overrides ||
                    found.head_sha != pull_request.head_sha ||
                    found.base_branch != pull_request.base_branch
            end

            CACHE_FILE = 'pull_request_cache.yml'

            # @return [void]
            def dump
                File.open(cache_file, 'w') do |file|
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
                    YAML.safe_load(File.read(cache_file), [Symbol, CachedPullRequest])
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
