# frozen_string_literal: true

require 'autoproj'
require 'net/http'
require 'uri'
require 'json'
require 'autoproj/daemon/github/pull_request'
require 'autoproj/daemon/github/push_event'

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
            def body(**options)
                BODY.merge(
                    params: BODY[:params].merge(branch: 'master').merge(**options)
                )
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

            # @param [Github::PullRequest] options
            # @return [Boolean]
            def build_pull_request(pull_request)
                repository = "#{pull_request.base_owner}/#{pull_request.base_name}"
                branch_name = BuildconfManager.branch_name_by_pull_request(pull_request)

                build(
                    branch: branch_name,
                    project: repository,
                    repository: "https://github.com/#{repository}",
                    revision: pull_request.head_sha
                )
            end

            # @param [Github::PushEvent] options
            # @return [Boolean]
            def build_mainline_push_event(push_event)
                repository = "#{push_event.owner}/#{push_event.name}"

                build(
                    branch: 'master',
                    project: repository,
                    repository: "https://github.com/#{repository}",
                    revision: push_event.head_sha
                )
            end

            # @param [Hash] options
            # @return [Boolean]
            def build(**options)
                http = Net::HTTP.new(uri.host, uri.port)
                request = Net::HTTP::Post.new(uri.request_uri, HEADER)
                request.body = body(options).to_json

                branch = body(**options)[:params][:branch]
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
