# frozen_string_literal: true

require "test_helper"

def github_url(path)
    "git://github.com/#{path}"
end

# Autoproj main module
module Autoproj
    # Main daemon module
    module Daemon
        describe PullRequestCache::CachedPullRequest do
            include Autoproj::Daemon::TestHelpers

            before do
                @ws = ws_create
                @cached = PullRequestCache::CachedPullRequest.new(
                    "git://github.com/rock-core/pkg",
                    1,
                    "master",
                    "abcdef"
                )
            end

            describe "#caches_pull_request?" do
                it "returns true if cached entry and PR are the same" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/pkg"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    assert @cached.caches_pull_request?(pr)
                end
                it "returns false if urls are different" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-drivers/pkg"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    refute @cached.caches_pull_request?(pr)
                end
                it "returns false if repo names are different" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    refute @cached.caches_pull_request?(pr)
                end
                it "returns false if numbers are different" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/pkg"),
                        number: 2,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    refute @cached.caches_pull_request?(pr)
                end
            end
        end

        describe PullRequestCache do
            include Autoproj::Daemon::TestHelpers

            before do
                @ws = ws_create
                @cache = PullRequestCache.new(ws)
            end
            describe "#add" do
                it "adds a pull request to the cache" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    @cache.add(pr)
                    assert_equal 1, @cache.pull_requests.size

                    cached = @cache.pull_requests.first
                    assert cached.git_url.same?(github_url("rock-core/foobar"))
                    assert_equal 1, cached.number
                    assert_equal "master", cached.base_branch
                    assert_equal "abcdef", cached.head_sha
                end
                it "updates an existing entry" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    @cache.add(pr)

                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "ghijkl"
                    )

                    @cache.add(pr)
                    assert_equal 1, @cache.pull_requests.size

                    cached = @cache.pull_requests.first
                    assert_equal "ghijkl", cached.head_sha
                end
            end

            describe "#cached" do
                it "returns the cached PR" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    pr.dependencies = [pr]
                    cached = @cache.add(pr)
                    assert_equal cached, @cache.cached(pr)
                end
                it "returns nil if PR is not cached" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    assert_nil @cache.cached(pr)
                end
            end

            describe "#dump" do
                it "creates a cache file with all PRs" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef",
                        draft: true
                    )
                    pr2 = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar2"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef",
                        draft: true
                    )
                    pr2.dependencies = []
                    pr.dependencies = [pr2]

                    @cache.add(pr)
                    @cache.dump

                    loaded_cache = PullRequestCache.load(@ws)
                    cached_deps = {
                        "repository" => "github.com/rock-core/foobar2",
                        "number" => 1,
                        "base_branch" => "master",
                        "head" => "abcdef",
                        "draft" => true
                    }

                    assert_equal @cache.pull_requests[0], loaded_cache.pull_requests[0]
                    assert_equal [cached_deps], loaded_cache.pull_requests[0].dependencies
                end
            end

            describe "#changed?" do
                it "returns true if PR is not cached" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    assert @cache.changed?(pr)
                end
                it "returns true if PR changed" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    @cache.add(pr)
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "ghijkl",
                        updated_at: Time.now + 2
                    )
                    assert @cache.changed?(pr)
                end
                it "returns true if recursive dependencies changed" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    pr2 = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar2"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    pr3 = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar3"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    pr3.dependencies = []
                    pr2.dependencies = []
                    pr.dependencies = [pr2]
                    @cache.add(pr)
                    pr2.dependencies = [pr3]
                    assert @cache.changed?(pr)
                end
                it "returns false if PR did not change" do
                    pr = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    pr2 = autoproj_daemon_create_pull_request(
                        repo_url: github_url("rock-core/foobar2"),
                        number: 1,
                        base_branch: "master",
                        head_sha: "abcdef"
                    )
                    pr.dependencies = [pr, pr2]
                    pr2.dependencies = []
                    @cache.add(pr)
                    pr.dependencies = [pr2, pr]
                    refute @cache.changed?(pr)
                end
            end

            describe "#reload" do
                it "initializes dependencies if cache format is old" do
                    cache_file = File.join(__dir__, "pull_request_cache_v1.yml")
                    File.write(@cache.cache_file, File.read(cache_file))

                    @cache.reload
                    refute_nil @cache.pull_requests.first.dependencies
                end
            end
        end
    end
end
