# frozen_string_literal: true

require 'autoproj/daemon/buildbot'
require 'autoproj/extensions/configuration'
require 'json'
require 'net/http'
require 'uri'

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        describe Buildbot do # rubocop: disable Metrics/BlockLength
            attr_reader :bb
            attr_reader :ws
            before do
                @ws = ws_create
                @bb = Buildbot.new(ws)
            end

            describe '#body' do
                it 'adds branch parameter if unset' do
                    expected = {
                        method: 'force',
                        jsonrpc: '2.0',
                        id: 1,
                        params: {
                            branch: 'master'
                        }
                    }
                    assert_equal expected, bb.body
                end
                it 'keeps branch parameter if set' do
                    expected = {
                        method: 'force',
                        jsonrpc: '2.0',
                        id: 1,
                        params: {
                            branch: 'feature'
                        }
                    }
                    assert_equal expected, bb.body(branch: 'feature')
                end
            end

            describe '#uri' do
                it 'formats buildbot url endpoint' do
                    ws.config.daemon_buildbot_host = 'bb-master'
                    ws.config.daemon_buildbot_port = 8666
                    ws.config.daemon_buildbot_scheduler = 'force-build'

                    assert_equal URI.parse(
                        'http://bb-master:8666/api/v2/forceschedulers/force-build'
                    ), bb.uri
                end
            end

            describe '#build' do # rubocop: disable Metrics/BlockLength
                it 'returns true if command is accepted' do
                    ws.config.daemon_buildbot_host = 'bb-master'
                    ws.config.daemon_buildbot_port = 8666
                    ws.config.daemon_buildbot_scheduler = 'force-build'

                    response = flexmock
                    response.should_receive(:body).and_return({
                        result: {},
                        error: nil,
                        id: 1
                    }.to_json)

                    flexmock(Net::HTTP)
                        .new_instances
                        .should_receive('request').and_return(response)

                    flexmock(bb).should_receive(:body).with(branch: 'feature')
                                .at_least.once.pass_thru
                    assert bb.build(branch: 'feature')
                end
                it 'returns false if command fails' do
                    ws.config.daemon_buildbot_host = 'bb-master'
                    ws.config.daemon_buildbot_port = 8666
                    ws.config.daemon_buildbot_scheduler = 'force-build'

                    response = flexmock
                    response.should_receive(:body).and_return({
                        result: {},
                        error: {
                            code: 1234,
                            message: 'Failed'
                        },
                        id: 1
                    }.to_json)

                    flexmock(Net::HTTP)
                        .new_instances
                        .should_receive('request').and_return(response)

                    refute bb.build
                end
            end
        end
    end
end
