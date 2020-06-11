# frozen_string_literal: true

require "autoproj/daemon/github/json_facade"

module Autoproj
    module Daemon
        module Github
            # A branch model representation
            class Branch < JSONFacade
                # @return [String]
                attr_reader :owner

                # @return [String]
                attr_reader :name

                def self.from_ruby_hash(owner, name, model)
                    from_json_string(owner, name, model.to_json)
                end

                def self.from_json_string(owner, name, model)
                    new(owner, name, JSON.parse(model))
                end

                def initialize(owner, name, model)
                    super(model)

                    @owner = owner
                    @name = name
                end

                # @return [String]
                def branch_name
                    @model["name"]
                end

                # @return [String]
                def sha
                    @model["commit"]["sha"]
                end
            end
        end
    end
end
