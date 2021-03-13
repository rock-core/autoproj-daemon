# frozen_string_literal: true

require "autoproj/daemon/git_api/json_facade"

module Autoproj
    module Daemon
        module GitAPI
            # A branch model representation
            class Branch < JSONFacade
                # @return [String]
                def branch_name
                    @model["name"]
                end

                # @return [String]
                def sha
                    @model["commit"]["sha"]
                end

                # @return [String]
                def commit_author
                    @model["commit"]["commit"]["author"]["name"]
                end

                # @return [Time]
                def commit_date
                    Time.parse(@model["commit"]["commit"]["author"]["date"])
                end
            end
        end
    end
end
