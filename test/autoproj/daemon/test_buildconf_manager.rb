# frozen_string_literal: true

require 'test_helper'

# Autoproj main module
module Autoproj
    # Main daemon module
    module Daemon
        describe BuildconfManager do # rubocop: disable Metrics/BlockLength
            before do
                @ws = ws_create
                @client = flexmock(Github::Client.new)
                @buildconf = PackageRepository.new(
                    'main configuration', 'rock-core', 'buildconf', {}, buildconf: true
                )
                @packages = []
                @cache = PullRequestCache.new(ws)

                @mock_package = flexmock
                @mock_package.should_receive(:importer)
                flexmock(@buildconf).should_receive(:autobuild).and_return(@mock_package)

                @manager = BuildconfManager.new(
                    @buildconf, @client, @packages, @cache, @ws
                )
            end

            def add_package(pkg_name, owner, name, vcs = {}, options = {})
                package = PackageRepository.new(pkg_name, owner, name, vcs)
                flexmock(package).should_receive(:autobuild).and_return(@mock_package)
                @packages << package
                return if options[:no_expect]

                branch = vcs[:branch] || vcs[:remote_branch] || 'master'
                @client.should_receive(:pull_requests).with(
                    owner, name, state: 'open', base: branch
                ).once.and_return(options[:pull_requests] || [])
            end

            describe '#update_pull_requests' do
                it 'does not poll same repository twice' do
                    add_package('drivers/iodrivers_base2', 'rock-core',
                                'drivers-iodrivers_base', {}, no_expect: true)
                    add_package('drivers/iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base')
                    add_package('drivers/gps_base2', 'rock-core',
                                'drivers-gps_base')
                    add_package('drivers/gps_base', 'rock-core',
                                'drivers-gps_base', { branch: 'devel' }, {})

                    @manager.update_pull_requests
                end

                it 'returns a flat and compact array of pull requests' do
                    add_package('drivers/iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base')

                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'drivers-gps_base',
                                             number: 1,
                                             base_branch: 'devel',
                                             head_sha: 'abcdef')

                    add_package('drivers/gps_base', 'rock-core',
                                'drivers-gps_base',
                                { branch: 'devel' }, pull_requests: [pr])

                    assert_equal [pr], @manager.update_pull_requests
                    assert_equal [pr], @manager.pull_requests
                end
            end
            describe '#update_branches' do
                it 'returns an array with the current branches' do
                    branches = []
                    branches << create_branch(
                        'rock-core', 'buildconf', branch_name: 'master', sha: 'abcdef'
                    )
                    branches << create_branch(
                        'rock-core', 'buildconf', branch_name: 'devel', sha: 'ghijkl'
                    )
                    @client.should_receive(:branches)
                           .with('rock-core', 'buildconf')
                           .and_return(branches)

                    assert_equal branches, @manager.update_branches
                    assert_equal branches, @manager.branches
                end
            end
            describe '#delete_stale_branches' do # rubocop: disable Metrics/BlockLength
                # rubocop: disable Metrics/BlockLength
                it 'deletes branches that do not have a PR open' do
                    one = create_branch(
                        'rock-core', 'buildconf', branch_name: 'master', sha: 'abcdef'
                    )
                    two = create_branch(
                        'rock-core', 'buildconf',
                        branch_name: 'autoproj/rock-core/drivers-iodrivers_base/pulls/12',
                        sha: 'abcdef'
                    )
                    three = create_branch(
                        'rock-core', 'buildconf',
                        branch_name: 'autoproj/rock-core/drivers-gps_base/pulls/55',
                        sha: 'ghijkl'
                    )
                    @client.should_receive(:branches)
                           .with('rock-core', 'buildconf')
                           .and_return([one, two, three])

                    pr_one = create_pull_request(base_owner: 'rock-core',
                                                 base_name: 'drivers-gps_base',
                                                 number: 55,
                                                 base_branch: 'master',
                                                 head_sha: 'abcdef')

                    add_package('drivers/gps_base', 'rock-core',
                                'drivers-gps_base',
                                { branch: 'master' }, pull_requests: [pr_one])

                    pr_two = create_pull_request(base_owner: 'rock-core',
                                                 base_name: 'drivers-iodrivers_base',
                                                 number: 54,
                                                 base_branch: 'master',
                                                 head_sha: 'abcdef')

                    add_package('drivers/iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base',
                                { branch: 'master' }, pull_requests: [pr_two])

                    @manager.update_branches
                    @manager.update_pull_requests
                    @client.should_receive(:delete_branch).with(two).once
                    @manager.delete_stale_branches
                end
                # rubocop: enable Metrics/BlockLength
            end
            describe '#create_missing_branches' do # rubocop: disable Metrics/BlockLength
                # rubocop: disable Metrics/BlockLength
                it 'creates branches for open PRs' do
                    existing_branch = create_branch(
                        'rock-core', 'buildconf',
                        branch_name: 'autoproj/rock-core/drivers-iodrivers_base/pulls/17',
                        sha: 'abcdef'
                    )
                    @client.should_receive(:branches)
                           .with('rock-core', 'buildconf')
                           .and_return([existing_branch])

                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'drivers-gps_base',
                                             number: 55,
                                             base_branch: 'master',
                                             head_sha: 'abcdef')

                    add_package('drivers/gps_base', 'rock-core',
                                'drivers-gps_base',
                                { branch: 'master' }, pull_requests: [pr])

                    new_branch_name = 'autoproj/rock-core/drivers-gps_base/pulls/55'
                    new_branch = create_branch(
                        'rock-core', 'buildconf',
                        branch_name: new_branch_name,
                        sha: 'abcdef'
                    )

                    pr_two = create_pull_request(base_owner: 'rock-core',
                                                 base_name: 'drivers-iodrivers_base',
                                                 number: 17,
                                                 base_branch: 'master',
                                                 head_sha: 'abcdef')

                    add_package('drivers/iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base',
                                { branch: 'master' }, pull_requests: [pr_two])

                    @manager.update_branches
                    @manager.update_pull_requests
                    flexmock(@manager).should_receive(:create_branch_for_pr)
                                      .with(new_branch_name, pr).once
                                      .and_return(new_branch)

                    created, existing = @manager.create_missing_branches
                    assert_equal [new_branch], created
                    assert_equal [existing_branch], existing
                end
                # rubocop: enable Metrics/BlockLength
            end
            # rubocop: disable Metrics/BlockLength
            describe '#trigger_build_if_branch_changed' do
                it 'does not trigger if PR did not change' do
                    branch = create_branch(
                        'rock-core', 'buildconf',
                        branch_name: 'autoproj/rock-core/drivers-iodrivers_base/pulls/12',
                        sha: 'abcdef'
                    )
                    @client.should_receive(:branches)
                           .with('rock-core', 'buildconf')
                           .and_return([branch])

                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'drivers-iodrivers_base',
                                             number: 12,
                                             base_branch: 'master',
                                             head_owner: 'g-arjones',
                                             head_name: 'drivers-iodrivers_base_fork',
                                             head_branch: 'add_feature',
                                             head_sha: 'abcdef')

                    add_package('drivers/iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base',
                                { branch: 'master' }, pull_requests: [pr])

                    add_package('iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base', {}, no_expect: true)

                    overrides = []
                    overrides << {
                        'drivers/iodrivers_base' => {
                            'github' => 'g-arjones/drivers-iodrivers_base_fork',
                            'remote_branch' => 'add_feature'
                        }
                    }
                    overrides << {
                        'iodrivers_base' => {
                            'github' => 'g-arjones/drivers-iodrivers_base_fork',
                            'remote_branch' => 'add_feature'
                        }
                    }
                    @cache.add(pr, overrides)

                    @manager.update_branches
                    @manager.update_pull_requests
                    flexmock(Autoproj).should_receive(:message).with(/Triggering/).never
                    @manager.trigger_build_if_branch_changed([branch])
                end
                it 'triggers if overrides changed' do
                    branch = create_branch(
                        'rock-core', 'buildconf',
                        branch_name: 'autoproj/rock-core/drivers-iodrivers_base/pulls/12',
                        sha: 'abcdef'
                    )
                    @client.should_receive(:branches)
                           .with('rock-core', 'buildconf')
                           .and_return([branch])

                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'drivers-iodrivers_base',
                                             number: 12,
                                             base_branch: 'master',
                                             head_owner: 'g-arjones',
                                             head_name: 'iodrivers_base_fork',
                                             head_branch: 'add_feature',
                                             head_sha: 'abcdef')

                    add_package('drivers/iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base',
                                { branch: 'master' }, pull_requests: [pr])

                    overrides = []
                    overrides << {
                        'drivers/iodrivers_base' => {
                            'github' => 'g-arjones/iodrivers_base_fork',
                            'remote_branch' => 'other_feature'
                        }
                    }

                    @cache.add(pr, overrides)
                    @manager.update_branches
                    @manager.update_pull_requests
                    branch_name = 'autoproj/rock-core/drivers-iodrivers_base/pulls/12'
                    flexmock(@manager.bb).should_receive(:build)
                                         .with(branch: branch_name).once

                    @manager.trigger_build_if_branch_changed([branch])
                end
                it 'triggers if PR head sha changed' do
                    branch = create_branch(
                        'rock-core', 'buildconf',
                        branch_name: 'autoproj/rock-core/drivers-iodrivers_base/pulls/12',
                        sha: 'abcdef'
                    )
                    @client.should_receive(:branches)
                           .with('rock-core', 'buildconf')
                           .and_return([branch])

                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'drivers-iodrivers_base',
                                             number: 12,
                                             base_branch: 'master',
                                             head_owner: 'g-arjones',
                                             head_name: 'iodrivers_base_fork',
                                             head_branch: 'add_feature',
                                             head_sha: 'abcdef')

                    add_package('drivers/iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base',
                                { branch: 'master' }, pull_requests: [pr])

                    overrides = []
                    overrides << {
                        'drivers/iodrivers_base' => {
                            'github' => 'g-arjones/iodrivers_base_fork',
                            'remote_branch' => 'add_feature'
                        }
                    }

                    pr_cached = create_pull_request(base_owner: 'rock-core',
                                                    base_name: 'drivers-iodrivers_base',
                                                    number: 12,
                                                    base_branch: 'master',
                                                    head_owner: 'g-arjones',
                                                    head_name: 'iodrivers_base_fork',
                                                    head_branch: 'add_feature',
                                                    head_sha: 'efghij')

                    @cache.add(pr_cached, overrides)
                    @manager.update_branches
                    @manager.update_pull_requests
                    branch_name = 'autoproj/rock-core/drivers-iodrivers_base/pulls/12'
                    flexmock(@manager.bb).should_receive(:build)
                                         .with(branch: branch_name).once

                    @manager.trigger_build_if_branch_changed([branch])
                end
                it 'triggers if PR base branch changed' do
                    branch = create_branch(
                        'rock-core', 'buildconf',
                        branch_name: 'autoproj/rock-core/drivers-iodrivers_base/pulls/12',
                        sha: 'abcdef'
                    )
                    @client.should_receive(:branches)
                           .with('rock-core', 'buildconf')
                           .and_return([branch])

                    pr = create_pull_request(base_owner: 'rock-core',
                                             base_name: 'drivers-iodrivers_base',
                                             number: 12,
                                             base_branch: 'master',
                                             head_owner: 'g-arjones',
                                             head_name: 'iodrivers_base_fork',
                                             head_branch: 'add_feature',
                                             head_sha: 'abcdef')

                    add_package('drivers/iodrivers_base', 'rock-core',
                                'drivers-iodrivers_base',
                                { branch: 'master' }, pull_requests: [pr])

                    overrides = []
                    overrides << {
                        'drivers/iodrivers_base' => {
                            'github' => 'g-arjones/iodrivers_base_fork',
                            'remote_branch' => 'add_feature'
                        }
                    }

                    pr_cached = create_pull_request(base_owner: 'rock-core',
                                                    base_name: 'drivers-iodrivers_base',
                                                    number: 12,
                                                    base_branch: 'develop',
                                                    head_owner: 'g-arjones',
                                                    head_name: 'iodrivers_base_fork',
                                                    head_branch: 'add_feature',
                                                    head_sha: 'abcdef')

                    @cache.add(pr_cached, overrides)
                    @manager.update_branches
                    @manager.update_pull_requests

                    branch_name = 'autoproj/rock-core/drivers-iodrivers_base/pulls/12'
                    flexmock(@manager.bb).should_receive(:build)
                                         .with(branch: branch_name).once
                    @manager.trigger_build_if_branch_changed([branch])
                end
            end
            # rubocop: enable Metrics/BlockLength
        end
    end
end
