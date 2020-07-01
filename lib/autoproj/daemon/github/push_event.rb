# frozen_string_literal: true

require "json"

module Autoproj
    module Daemon
        module Github
            # A PushEvent model representation
            class PushEvent
                # @return [Hash]
                attr_reader :model

                def initialize(model)
                    @model = JSON.parse(model.to_json)
                end

                def initialize_copy(_)
                    super
                    @model = @model.dup
                end

                def author
                    @model["actor"]["login"]
                end

                def owner
                    @model["repo"]["name"].split("/").first
                end

                def name
                    @model["repo"]["name"].split("/").last
                end

                def branch
                    @model["payload"]["ref"].split("/")[2]
                end

                def head_sha=(sha)
                    @model["payload"]["head"] = sha.to_str
                end

                def head_sha
                    @model["payload"]["head"]
                end

                def created_at
                    Time.parse(@model["created_at"])
                end

                def ==(other)
                    model == other.model
                end
            end
        end
    end
end
