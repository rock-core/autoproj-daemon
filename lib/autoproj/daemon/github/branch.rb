# frozen_string_literal: true

require 'json'

module Autoproj
    module Daemon
        module Github
            # A branch model representation
            class Branch
                # @return [String]
                attr_reader :owner

                # @return [String]
                attr_reader :name

                def initialize(owner, name, model)
                    @owner = owner
                    @name = name
                    @model = JSON.parse(model.to_json)
                end

                # @return [String]
                def branch_name
                    @model['name']
                end

                # @return [String]
                def sha
                    @model['commit']['sha']
                end
            end
        end
    end
end