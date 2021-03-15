# frozen_string_literal: true

require "autoproj/daemon/git_api/branch"
require "autoproj/daemon/git_api/pull_request"
require "autoproj/daemon/git_api/url"

module Autoproj
    module Daemon
        module GitAPI
            # A Git service interface
            class Service
                # @return [String]
                attr_reader :host

                # @return [String]
                attr_reader :api_endpoint

                RateLimit = Struct.new(:remaining, :resets_in)

                def initialize(
                    host: nil,
                    api_endpoint: nil,
                    access_token: nil
                )
                    @host = host
                    @api_endpoint = api_endpoint || default_endpoint

                    unless @api_endpoint
                        raise Autoproj::ConfigError,
                              "API endpoint configuration missing for #{host}"
                    end
                    return if access_token

                    raise Autoproj::ConfigError,
                          "API key configuration missing for #{host}"
                end

                # @param [GitAPI::URL] url
                # @param [String] base
                # @param [String] state
                # @return [Array<PullRequest>]
                def pull_requests(git_url, base: nil, state: nil); end

                # @param [GitAPI::URL] git_url
                # @return [Array<Branch>]
                def branches(git_url); end

                # @param [Branch] branch A branch to delete
                # @return [void]
                def delete_branch(branch); end

                # @param [GitAPI::URL] git_url
                # @param [String] branch_name
                # @return [void]
                def delete_branch_by_name(git_url, branch_name); end

                # @param [GitAPI::URL] git_url
                # @param [String] branch_name
                # @return [Branch]
                def branch(git_url, branch_name); end

                # @return [RateLimit]
                def rate_limit; end

                # @return [String]
                def default_endpoint; end

                # @param [String] ref
                # @param [GitAPI::PullRequest] pull_request
                # @return [String]
                def extract_info_from_pull_request_ref(ref, pull_request); end
            end
        end
    end
end
