# frozen_string_literal: true

module Autoproj
    module Extensions
        # Autoproj's main configuration scope
        module Configuration
            # The project name
            #
            # Passed as-is to buildbot's change system to recognize which
            # builder to use
            def daemon_project
                get("daemon_project", nil)
            end

            # Sets the project name
            def daemon_project=(name)
                set("daemon_project", name, true)
            end

            # Sets the pull request's polling period
            # @param [Integer] period the polling period, in seconds
            def daemon_polling_period=(period)
                set("daemon_polling_period", period, true)
            end

            # The pull request's polling period
            #
            # @return [Integer]
            def daemon_polling_period
                get("daemon_polling_period", 60)
            end

            # The buildbot host/ip
            #
            # @return [String]
            def daemon_buildbot_host
                get("daemon_buildbot_host", "localhost")
            end

            # Sets buildbot host/ip
            # @param [String] host Buildbot host/ip
            # @return [void]
            def daemon_buildbot_host=(host)
                set("daemon_buildbot_host", host, true)
            end

            # Sets buildbot http port
            # @param [Integer] port Buildbot http port
            def daemon_buildbot_port=(port)
                set("daemon_buildbot_port", port, true)
            end

            # Buildbot http port
            #
            # @return [Integer]
            def daemon_buildbot_port
                get("daemon_buildbot_port", 8010)
            end

            # Longest period to consider PRs and events (in days)
            #
            # @return [Integer]
            def daemon_max_age
                get("daemon_max_age", 120)
            end

            # Sets events and PR max age
            # @param [Integer] max_age Period, in days
            # @return [void]
            def daemon_max_age=(max_age)
                set("daemon_max_age", max_age, true)
            end

            # Supported services configuration
            # The returned value is a hash in the following format:
            #
            # "github.com" => {
            #   "service" => "github",
            #   "api_endpoint" => "https://api.github.com"
            #   "access_token" => "abcdef"
            # }
            #
            # This hash will be merged with Autoproj::Daemon::GitAPI::Client::SERVICES.
            # The resulting hash will be used to determine which git services will be
            # supported by the daemon instance. All services require all fields to be
            # defined but since the daemon has internal defaults, the user must provide
            # at least the missing keys for a given service (i.e: access_token for
            # github.com)
            #
            # @return [Hash]
            def daemon_services
                get("daemon_services", {})
            end

            # @param [String] str
            # @return [String]
            def sanitize_string(str)
                str&.to_s&.strip&.downcase
            end

            # Sets service parameters
            #
            # @param [String] host
            # @param [String] access_token
            # @param [String] api_endpoint
            # @param [String] service
            def daemon_set_service(
                host,
                access_token,
                api_endpoint = nil,
                service = nil
            )
                host = sanitize_string(host).sub(/^www./, "")
                options = {
                    "service" => sanitize_string(service),
                    "api_endpoint" => sanitize_string(api_endpoint),
                    "access_token" => access_token.to_s.strip
                }

                options.compact!
                options.delete_if { |_, v| v.empty? }

                set(
                    "daemon_services",
                    daemon_services.merge({ host => options })
                )
            end

            # Removes user defined parameters for a given service
            #
            # @param [String] host
            def daemon_unset_service(host)
                host = sanitize_string(host).sub(/^www./, "")
                set("daemon_services", daemon_services.delete_if { |k, _| k == host })
            end
        end
    end
end
