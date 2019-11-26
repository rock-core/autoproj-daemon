# frozen_string_literal: true

require 'test_helper'

# Autoproj main module
module Autoproj
    # Main daemon module
    module Daemon
        # rubocop: disable Metrics/BlockLength
        describe PullRequestCache::CachedPullRequest do
            before do
                @ws = ws_create
                @cached = PullRequestCache::CachedPullRequest.new(
                    'rock-core',
                    'pkg',
                    1,
                    'master',
                    'abcdef'
                )
            end

            describe '#caches_pull_request?' do # rubocop: disable Metrics/BlockLength
                it 'returns true if cached entry and PR are the same' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'pkg',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    assert @cached.caches_pull_request?(pr)
                end
                it 'returns false if base owners are different' do
                    pr = create_pull_request(base_owner: 'rock-drivers',
                                             base_name: 'pkg',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    refute @cached.caches_pull_request?(pr)
                end
                it 'returns false if base names are different' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    refute @cached.caches_pull_request?(pr)
                end
                it 'returns false if numbers are different' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'pkg',
                                             number: 2,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    refute @cached.caches_pull_request?(pr)
                end
            end
        end
        # rubocop: enable Metrics/BlockLength

        describe PullRequestCache do # rubocop: disable Metrics/BlockLength
            before do
                @ws = ws_create
                @cache = PullRequestCache.new(ws)
            end
            describe '#add' do # rubocop: disable Metrics/BlockLength
                it 'adds a pull request to the cache' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    @cache.add(pr, ['pkg' => { 'remote_branch' => 'develop' }])
                    assert_equal 1, @cache.pull_requests.size

                    cached = @cache.pull_requests.first
                    assert_equal 'foobar', cached.base_name
                    assert_equal 'rock-core', cached.base_owner
                    assert_equal 1, cached.number
                    assert_equal 'master', cached.base_branch
                    assert_equal 'abcdef', cached.head_sha
                    assert_equal ['pkg' => { 'remote_branch' => 'develop' }],
                                 cached.overrides
                end
                it 'updates an existing entry' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    @cache.add(pr, ['pkg' => { 'remote_branch' => 'develop' }])

                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'ghijkl')

                    @cache.add(pr, ['pkg' => { 'remote_branch' => 'develop' }])
                    assert_equal 1, @cache.pull_requests.size

                    cached = @cache.pull_requests.first
                    assert_equal 'ghijkl', cached.head_sha
                end
            end

            describe '#cached' do
                it 'returns the cached PR' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    cached = @cache.add(pr, ['pkg' => { 'remote_branch' => 'develop' }])
                    assert_equal cached, @cache.cached(pr)
                end
                it 'returns nil if PR is not cached' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    assert_nil @cache.cached(pr)
                end
            end

            describe '#dump' do
                it 'creates a cache file with all PRs' do
                    pr = create_pull_request(
                        base_owner: 'rock-core',
                        base_name: 'foobar',
                        number: 1,
                        base_branch: 'master',
                        head_sha: 'abcdef'
                    )
                    @cache.add(pr, ['pkg' => { 'remote_branch' => 'develop' }])
                    @cache.dump

                    loaded_cache = PullRequestCache.load(@ws)
                    assert_equal @cache.pull_requests[0], loaded_cache.pull_requests[0]
                end
            end

            describe '#changed?' do # rubocop: disable Metrics/BlockLength
                it 'returns true if PR is not cached' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    assert @cache.changed?(
                        pr, ['pkg' => { 'remote_branch' => 'develop' }]
                    )
                end
                it 'returns true if PR changed' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    @cache.add(pr, ['pkg' => { 'remote_branch' => 'develop' }])
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'ghijkl',
                                             updated_at: Time.now + 2)
                    assert @cache.changed?(
                        pr, ['pkg' => { 'remote_branch' => 'develop' }]
                    )
                end
                it 'returns false if PR did not change' do
                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'foobar',
                                             number: 1,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')
                    @cache.add(pr, ['pkg' => { 'remote_branch' => 'develop' }])
                    refute @cache.changed?(
                        pr, ['pkg' => { 'remote_branch' => 'develop' }]
                    )
                end
            end
        end
    end
end
