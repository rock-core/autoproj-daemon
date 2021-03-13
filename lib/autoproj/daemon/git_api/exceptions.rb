# frozen_string_literal: true

module Autoproj
    module Daemon
        module GitAPI
            ConnectionFailed = Class.new(RuntimeError)
            TooManyRequests = Class.new(RuntimeError)
            NotFound = Class.new(RuntimeError)
        end
    end
end
