# frozen_string_literal: true

module Autoproj
    module Daemon
        module Github
            # A PullRequest model representation
            class PullRequest
                def initialize(model)
                    @model = model
                end

                # @return [Boolean]
                def open?
                    @model['state'] == 'open'
                end

                # @return [Integer]
                def number
                    @model['number']
                end

                # @return [String]
                def title
                    @model['title']
                end

                # @return [String]
                def base_branch
                    @model['base']['ref']
                end

                # @return [String]
                def head_branch
                    @model['head']['ref']
                end

                # @return [String]
                def base_sha
                    @model['base']['sha']
                end

                # @return [String]
                def head_sha
                    @model['head']['sha']
                end

                # @return [String]
                def base_owner
                    @model['base']['user']['login']
                end

                # @return [String]
                def head_owner
                    @model['head']['user']['login']
                end

                # @return [String]
                def base_name
                    @model['base']['repo']['name']
                end

                # @return [String]
                def head_name
                    @model['head']['repo']['name']
                end
            end
        end
    end
end
