# frozen_string_literal: true

require "json"
require "time"

module Autoproj
    module Daemon
        module Github
            # Base class for classes that provide a friendly interface on top
            # of JSON objects
            class JSONFacade
                # @return [Hash]
                attr_reader :model

                def self.from_ruby_hash(hash)
                    from_json_string(hash.to_json)
                end

                def self.from_json_string(string)
                    new(JSON.parse(string))
                end

                def initialize(model)
                    @model = model
                end

                def ==(other)
                    @model == other.model
                end

                def eql?(other)
                    @model.eql?(other.model)
                end

                def hash
                    @model.hash
                end

                def initialize_copy(_)
                    super
                    @model = @model.dup
                end
            end
        end
    end
end
