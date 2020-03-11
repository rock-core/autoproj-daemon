# frozen_string_literal: true

require 'test_helper'
require 'autoproj/daemon/buildbot'

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        describe Buildbot do # rubocop: disable Metrics/BlockLength
            attr_reader :bb
            attr_reader :ws

            include Autoproj::Daemon::TestHelpers
            before do
                @ws = ws_create
                @bb = Buildbot.new(ws, project: 'wetpaint')
            end

            describe '#uri' do
                it 'formats buildbot url endpoint' do
                    ws.config.daemon_buildbot_host = 'bb-master'
                    ws.config.daemon_buildbot_port = 8666

                    assert_equal URI.parse(
                        'http://bb-master:8666/change_hook/base'
                    ), bb.uri
                end
            end

            describe '#build' do # rubocop: disable Metrics/BlockLength
                it 'returns true if command is accepted' do
                    ws.config.daemon_buildbot_host = 'bb-master'
                    ws.config.daemon_buildbot_port = 8666

                    response = flexmock
                    response.should_receive(code: '200')

                    flexmock(Net::HTTP)
                        .new_instances
                        .should_receive('request').and_return(response)

                    assert bb.build
                end
                it 'returns false if command fails' do
                    ws.config.daemon_buildbot_host = 'bb-master'
                    ws.config.daemon_buildbot_port = 8666

                    response = flexmock
                    response.should_receive(code: '404', body: 'some error')

                    flexmock(Net::HTTP)
                        .new_instances
                        .should_receive('request').and_return(response)

                    refute bb.build
                end
            end
            describe '#build_pull_request' do
                it 'adds buildbot force build paramaters' do
                    now = Time.now
                    flexmock(bb).should_receive(:build).with(
                        author: 'contributor',
                        branch: 'autoproj/tidewise/drivers-gps_ublox/pulls/22',
                        category: 'pull_request',
                        codebase: '',
                        committer: 'contributor',
                        repository: 'tidewise/drivers-gps_ublox',
                        revision: 'abcdef',
                        revlink: 'https://github.com/tidewise/drivers-gps_ublox/pull/22',
                        when_timestamp: now.tv_sec
                    ).once

                    pr = autoproj_daemon_add_pull_request(
                        base_owner: 'tidewise',
                        base_name: 'drivers-gps_ublox',
                        number: 22,
                        base_branch: 'master',
                        head_owner: 'contributor',
                        head_name: 'drivers-gps_ublox_fork',
                        head_branch: 'feature',
                        head_sha: 'abcdef',
                        updated_at: now
                    )

                    bb.build_pull_request(pr)
                end
            end
            describe '#build_mainline_push_event' do
                it 'adds buildbot force build paramaters' do
                    now = Time.now
                    flexmock(bb).should_receive(:build).with(
                        author: 'g-arjones',
                        branch: 'master',
                        category: 'push',
                        codebase: '',
                        committer: 'g-arjones',
                        repository: 'tidewise/drivers-gps_ublox',
                        revision: 'abcdef',
                        revlink: 'https://github.com/tidewise/drivers-gps_ublox',
                        when_timestamp: now.tv_sec
                    ).once

                    event = autoproj_daemon_add_push_event(
                        author: 'g-arjones',
                        owner: 'tidewise',
                        name: 'drivers-gps_ublox',
                        branch: 'feature',
                        head_sha: 'abcdef',
                        created_at: now
                    )

                    bb.build_mainline_push_event(event)
                end
            end
        end
    end
end
