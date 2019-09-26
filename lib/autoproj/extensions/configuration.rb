# frozen_string_literal: true

module Autoproj
    module Extensions
        # Autoproj's main configuration scope
        module Configuration
            # Sets the github api key to be used for authentication.
            # @param [String] api_key the github api key
            def daemon_api_key=(api_key)
                set('daemon_api_key', api_key, true)
            end

            # The github api key for authentication
            #
            # @return [String]
            def daemon_api_key
                get('daemon_api_key', nil)
            end

            # Sets the pull request's polling period
            # @param [Integer] period the polling period, in seconds
            def daemon_polling_period=(period)
                set('daemon_polling_period', period, true)
            end

            # The pull request's polling period
            #
            # @return [Integer]
            def daemon_polling_period
                get('daemon_polling_period', 60)
            end
        end
    end
end
