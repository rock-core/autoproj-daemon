# frozen_string_literal: true

require "autoproj/daemon/github/json_facade"
require "autoproj/daemon/github/pull_request"

module Autoproj
    module Daemon
        module Github
            # A PullRequestEvent model representation
            class PullRequestEvent < JSONFacade
                def pull_request
                    PullRequest.new(@model["payload"]["pull_request"])
                end

                def created_at
                    Time.parse(@model["created_at"])
                end
            end
        end
    end
end
