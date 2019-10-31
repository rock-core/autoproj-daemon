# frozen_string_literal: true

require 'test_helper'
require 'rubygems/package'

# Autoproj main module
module Autoproj
    describe Configuration do # rubocop: disable Metrics/BlockLength
        before do
            @config = Configuration.new
        end

        describe '#daemon_api_key' do
            it 'sets the github api key' do
                @config.daemon_api_key = 'abcdefg'
                assert_equal 'abcdefg', @config.daemon_api_key
            end

            it 'returns nil if github api key not set' do
                refute @config.daemon_api_key
            end
        end

        describe '#daemon_polling_period' do
            it 'sets the polling period' do
                @config.daemon_polling_period = 80
                assert_equal 80, @config.daemon_polling_period
            end

            it 'returns default if polling period not set' do
                assert_equal 60, @config.daemon_polling_period
            end
        end

        describe '#daemon_buildbot_host' do
            it 'sets buildbot host/ip' do
                @config.daemon_buildbot_host = 'bb-master'
                assert_equal 'bb-master', @config.daemon_buildbot_host
            end

            it 'returns localhost if buildbot host not set' do
                assert_equal 'localhost', @config.daemon_buildbot_host
            end
        end

        describe '#daemon_buildbot_port' do
            it 'sets buildbot port' do
                @config.daemon_buildbot_port = 1234
                assert_equal 1234, @config.daemon_buildbot_port
            end

            it 'returns 8010 if buildbot port not set' do
                assert_equal 8010, @config.daemon_buildbot_port
            end
        end

        describe '#daemon_buildbot_scheduler' do
            it 'sets buildbot scheduler' do
                @config.daemon_buildbot_scheduler = 'foo-scheduler'
                assert_equal 'foo-scheduler', @config.daemon_buildbot_scheduler
            end

            it 'returns build-force if buildbot scheduler not set' do
                assert_equal 'build-force', @config.daemon_buildbot_scheduler
            end
        end

        describe '#daemon_max_age' do
            it 'sets events and prs max age' do
                @config.daemon_max_age = 90
                assert_equal 90, @config.daemon_max_age
            end

            it 'returns 120 if events and prs max age not set' do
                assert_equal 120, @config.daemon_max_age
            end
        end
    end
end
