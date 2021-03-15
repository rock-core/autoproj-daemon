# frozen_string_literal: true

require "autoproj"
require "autoproj/daemon/git_api/services/github"
require "autoproj/daemon/git_api/exceptions"
require "autoproj/daemon/git_api/branch"
require "autoproj/daemon/git_api/pull_request"

module Autoproj
    module Daemon
        module GitAPI
            # An adapter for Git services APIs
            class Client
                # @param [Hash]
                attr_reader :services

                SERVICES = {
                    "github.com" => {
                        "service" => "github",
                        "api_endpoint" => "https://api.github.com",
                        "access_token" => nil
                    }
                }.freeze

                # @param [Autoproj::Workspace] ws
                def initialize(ws)
                    @ws = ws
                    @services = {}

                    load_configuration
                end

                # @return [Hash]
                def load_unknown_services
                    all_services = SERVICES.dup
                    config = @ws.config.daemon_services

                    config.each do |k, v|
                        all_services[k] = v unless all_services.key?(k)
                    end

                    all_services
                end

                # @param [String]
                # @return [void]
                def validate_service_name(service, host)
                    return if service && Services.respond_to?(service)

                    message = if service
                                  "Service '#{service}' is not supported (#{host})"
                              else
                                  "Service parameter missing for #{host} (i.e github)"
                              end
                    raise Autoproj::ConfigError, message
                end

                # @return [void]
                def load_configuration
                    all_services = load_unknown_services
                    config = @ws.config.daemon_services

                    all_services.each do |host, params|
                        params = params.merge(config[host].compact) if config[host]
                        service = params["service"]
                        endpoint = params["api_endpoint"]
                        token = params["access_token"]

                        validate_service_name(service, host)

                        begin
                            @services[host] = Services.send(
                                service,
                                host: host,
                                api_endpoint: endpoint,
                                access_token: token
                            )
                        rescue Autoproj::ConfigError
                            next
                        end
                    end
                end

                # @param [String] url
                # @return [Boolean]
                def supports?(url)
                    @services.key?(URL.new(url).host)
                end

                # @param [String] url
                # @return [GitAPI::Service]
                def service(url)
                    git_url = URL.new(url)
                    unless supports?(url)
                        raise ArgumentError, "Unsupported service (#{git_url.host})"
                    end

                    @services[git_url.host]
                end

                # @return [String]
                def humanize_time(secs)
                    [[60, :s], [60, :m], [24, :h]].map do |count, name|
                        if secs > 0
                            secs, n = secs.divmod(count)
                            "#{n.to_i}#{name}" unless n.to_i == 0
                        end
                    end.compact.reverse.join("")
                end

                # @param [GitAPI::Service] service
                # @return [void]
                def check_rate_limit_and_wait(service)
                    return if service.rate_limit.remaining > 0

                    wait_for = service.rate_limit.resets_in + 1
                    Autoproj.message "API calls rate limit exceeded, waiting for "\
                                     "#{humanize_time(wait_for)} (#{service.host})"
                    sleep wait_for
                end

                # @param [GitAPI::Service] service
                # @return [void]
                def with_retry(service, times = 5)
                    retries ||= 0
                    check_rate_limit_and_wait(service)
                    yield
                rescue GitAPI::ConnectionFailed
                    retries += 1
                    if retries <= times
                        sleep 1
                        retry
                    end
                    raise
                rescue GitAPI::TooManyRequests
                    retry
                end

                # @param [String] url
                # @param [String] base
                # @param [String] state
                # @return [Array<PullRequest>]
                def pull_requests(url, base: nil, state: nil)
                    service = service(url)
                    git_url = URL.new(url)

                    with_retry(service) do
                        service.pull_requests(git_url, base: base, state: state)
                    end
                end

                # @param [String] url
                # @return [Array<Branch>]
                def branches(url)
                    service = service(url)
                    git_url = URL.new(url)

                    with_retry(service) do
                        service.branches(git_url)
                    end
                end

                # @param [Branch] branch A branch to delete
                # @return [void]
                def delete_branch(branch)
                    service = service(branch.git_url.raw)

                    with_retry(service) do
                        service.delete_branch(branch.git_url, branch.branch_name)
                    end
                end

                # @param [String] url
                # @param [String] branch_name
                # @return [void]
                def delete_branch_by_name(url, branch_name)
                    service = service(url)
                    git_url = URL.new(url)

                    with_retry(service) do
                        service.delete_branch(git_url, branch_name)
                    end
                end

                # @param [String] url
                # @param [String] branch_name
                # @return [Branch]
                def branch(url, branch_name)
                    service = service(url)
                    git_url = URL.new(url)

                    with_retry(service) do
                        service.branch(git_url, branch_name)
                    end
                end

                # @param [String] ref
                # @param [GitAPI::PullRequest] pull_request
                # @return [String]
                def extract_info_from_pull_request_ref(ref, pull_request)
                    service(pull_request.git_url.raw)
                        .extract_info_from_pull_request_ref(ref, pull_request)
                end
            end
        end
    end
end
