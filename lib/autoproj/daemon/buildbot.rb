# frozen_string_literal: true

require 'autoproj'
require 'net/http'
require 'uri'
require 'json'

module Autoproj
    module Daemon
        # Buildbot integration class
        class Buildbot
            # @return [Autoproj::Workspace]
            attr_reader :ws

            HEADER = { 'Content-Type' => 'application/json' }.freeze
            BODY = {
                method: 'force',
                jsonrpc: '2.0',
                id: 1,
                params: {
                }
            }.freeze

            # @param [Autoproj::Workspace] workspace
            def initialize(workspace)
                @ws = workspace
            end

            # @param [Hash] options
            # @return [Hash]
            def validate_options(options = {})
                options[:branch] ||= 'master'
                options
            end

            # @param [Hash] options
            # @return [Hash]
            def body(**options)
                body = BODY
                body[:params].merge!(validate_options(options))
                body
            end

            # @return [URI]
            def uri
                URI.parse(
                    "http://#{ws.config.daemon_buildbot_host}:"\
                        "#{ws.config.daemon_buildbot_port}/"\
                        'api/v2/forceschedulers/'\
                        "#{ws.config.daemon_buildbot_scheduler}"
                )
            end

            # @param [Hash] options
            # @return [(Boolean, String)]
            def build(**options)
                http = Net::HTTP.new(uri.host, uri.port)
                request = Net::HTTP::Post.new(uri.request_uri, HEADER)
                request.body = body(options).to_json

                branch = body(options)[:params][:branch]
                Autoproj.message "Triggering build on #{branch}"

                response = http.request(request)
                result = JSON.parse(response.body)
                return true unless result['error']

                Autoproj.error result['error']['message']
                false
            end
        end
    end
end
