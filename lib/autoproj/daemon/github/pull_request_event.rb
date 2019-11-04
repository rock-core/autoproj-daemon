# frozen_string_literal: true

require 'autoproj/daemon/github/pull_request'
require 'json'

module Autoproj
    module Daemon
        module Github
            # A PullRequestEvent model representation
            class PullRequestEvent
                def initialize(model)
                    @model = JSON.parse(model.to_json)
                end

                def pull_request
                    PullRequest.new(@model['payload']['pull_request'])
                end

                def created_at
                    Time.parse(@model['created_at'])
                end
            end
        end
    end
end
