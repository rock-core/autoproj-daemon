# frozen_string_literal: true

require "autoproj/daemon/github/client"
require "autoproj/daemon/github/pull_request"
require "octokit"

module Autoproj
    module Daemon
        # A class that retrievers overrides from a pull request
        class OverridesRetriever
            DEPENDS_ON_RX = /(?:.*depends?(?:\s+on)?\s*\:?\s*\n)(.*)/mi.freeze
            OPEN_TASK_RX = %r{(?:-\s*\[\s*\]\s*)([A-Za-z\d+_\-\:\/\#\.]+)}.freeze

            PULL_REQUEST_URL_RX =
                %r{https?\:\/\/(?:\w+\.)?github.com(?:\/+)
                ([A-Za-z\d+_\-\.]+)(?:\/+)([A-Za-z\d+_\-\.]+)(?:\/+)pull(?:\/+)(\d+)}x
                .freeze

            OWNER_NAME_AND_NUMBER_RX = %r{([A-Za-z\d+_\-\.]+)\/
                ([A-Za-z\d+_\-\.]+)\#(\d+)}x.freeze

            NUMBER_RX = /\#(\d+)/.freeze

            # @return [Github::Client]
            attr_reader :client

            # @param [Github::Client] client
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
            # @param [Github::PullRequest] pull_request
            # @return [Github::PullRequest, nil]
            def task_to_pull_request(task, pull_request)
                if (match = PULL_REQUEST_URL_RX.match(task))
                    owner, name, number = match[1..-1]
                elsif (match = OWNER_NAME_AND_NUMBER_RX.match(task))
                    owner, name, number = match[1..-1]
                elsif (match = NUMBER_RX.match(task))
                    owner = pull_request.base_owner
                    name = pull_request.base_name
                    number = match[1]
                else
                    return nil
                end

                number = number.to_i
                client.pull_requests(owner, name).find { |pr| pr.number == number }
            rescue Octokit::NotFound
                nil
            end

            # @param [Array<Github::PullRequest>] visited
            # @param [Github::PullRequest] pull_request
            # @return [Boolean]
            def visited?(visited, pull_request)
                visited.any? do |pr|
                    pr.base_owner == pull_request.base_owner &&
                        pr.base_name == pull_request.base_name &&
                        pr.number == pull_request.number
                end
            end

            # @param [Github::PullRequest] pull_request
            # @return [Array<Github::PullRequest>]
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
