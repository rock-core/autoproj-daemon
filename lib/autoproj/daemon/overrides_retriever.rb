# frozen_string_literal: true

require "autoproj/daemon/git_api/client"
require "autoproj/daemon/git_api/exceptions"
require "autoproj/daemon/git_api/pull_request"
require "octokit"

module Autoproj
    module Daemon
        # A class that retrievers overrides from a pull request
        class OverridesRetriever
            DEPENDS_ON_RX = /(?:.*depends?(?:\s+on)?\s*:?\s*\n)(.*)/mi.freeze
            OPEN_TASK_RX = /(?:-\s*\[\s*\]\s*)(.*)/.freeze

            # @return [GitAPI::Client]
            attr_reader :client

            # @param [GitAPI::Client] client
            def initialize(client, pull_requests)
                @client = client
                @pull_requests = pull_requests
            end

            # @param [String] body
            # @return [Array<String>]
            def parse_task_list(body)
                return [] unless (m = DEPENDS_ON_RX.match(body))

                lines = m[1].each_line.map do |l|
                    l.strip!
                    l unless l.empty?
                end.compact

                valid = []
                lines.each do |l|
                    break unless l =~ /^-/

                    valid << l
                end

                valid.join("\n").scan(OPEN_TASK_RX).flatten
            end

            # @param [String] task
            # @param [GitAPI::PullRequest] pull_request
            # @return [GitAPI::PullRequest, nil]
            def task_to_pull_request(task, pull_request)
                url, number = client.extract_info_from_pull_request_ref(
                    task, pull_request
                )
                return unless url && number

                url = GitAPI::URL.new(url)
                number = number.to_i
                @pull_requests.find { |pr| pr.git_url == url && pr.number == number }
            rescue GitAPI::NotFound
                nil
            end

            # Return the direct dependencies of this pull request
            #
            # @param [GitAPI::PullRequest] pull_request
            # @return [Array<GitAPI::PullRequest>]
            def dependencies(pull_request)
                parse_task_list(pull_request.body).map do |task|
                    task_to_pull_request(task, pull_request)
                end.compact
            end

            # Resolve the dependencies of all pull requests
            def resolve_dependencies
                @pull_requests.each do |pr|
                    pr.dependencies = dependencies(pr)
                end
            end
        end
    end
end
