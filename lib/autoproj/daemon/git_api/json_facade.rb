# frozen_string_literal: true

require "json"
require "time"

module Autoproj
    module Daemon
        module GitAPI
            # Base class for classes that provide a friendly interface on top
            # of JSON objects
            class JSONFacade
                # @return [GitAPI::URL]
                attr_reader :git_url

                # @return [Hash]
                attr_reader :model

                def self.from_ruby_hash(git_url, model)
                    from_json_string(git_url, model.to_json)
                end

                def self.from_json_string(git_url, model)
                    new(git_url, JSON.parse(model))
                end

                def initialize(git_url, model)
                    @git_url = git_url
                    @model = model
                end

                def ==(other)
                    @git_url == other.git_url && @model == other.model
                end

                def eql?(other)
                    @git_url.eql?(other.git_url) && @model.eql?(other.model)
                end

                def hash
                    [@git_url, @model].hash
                end

                def initialize_copy(_)
                    super
                    @model = @model.dup
                    @git_url = @git_url.dup
                end
            end
        end
    end
end
