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

            # Sets the github api key to be used for authentication.
            # @param [String] api_key the github api key
            def daemon_api_key=(api_key)
                set("daemon_api_key", api_key, true)
            end

            # The github api key for authentication
            #
            # @return [String]
            def daemon_api_key
                get("daemon_api_key", nil)
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
        end
    end
end
