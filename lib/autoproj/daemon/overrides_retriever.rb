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
            OPEN_TASK_RX = %r{(?:-\s*\[\s*\]\s*)([A-Za-z\d+_\-:/\#.]+)}.freeze

            # @return [GitAPI::Client]
            attr_reader :client

            # @param [GitAPI::Client] client
            def initialize(client)
                @client = client
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

                number = number.to_i
                client.pull_requests(url).find { |pr| pr.number == number }
            rescue GitAPI::NotFound
                nil
            end

            # @param [Array<GitAPI::PullRequest>] visited
            # @param [GitAPI::PullRequest] pull_request
            # @return [Boolean]
            def visited?(visited, pull_request)
                visited.any? do |pr|
                    pr.git_url == pull_request.git_url && pr.number == pull_request.number
                end
            end

            # @param [GitAPI::PullRequest] pull_request
            # @return [Array<GitAPI::PullRequest>]
            def retrieve_dependencies(pull_request, visited = [], deps = [])
                visited << pull_request
                dependencies = parse_task_list(pull_request.body).map do |task|
                    task_to_pull_request(task, pull_request)
                end.compact

                dependencies.each do |pr|
                    next if visited?(visited, pr)

                    deps << pr
                    retrieve_dependencies(pr, visited, deps)
                end
                deps
            end
        end
    end
end
