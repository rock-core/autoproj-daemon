# frozen_string_literal: true

require 'test_helper'
require 'rubygems/package'

# Autoproj main module
module Autoproj
    describe Configuration do
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
    end
end
