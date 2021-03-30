# frozen_string_literal: true

require "autoproj/daemon/git_api/json_facade"

module Autoproj
    module Daemon
        module GitAPI
            # A PullRequest model representation
            class PullRequest < JSONFacade
                # @return [Boolean]
                def open?
                    @model["state"] == "open"
                end

                def open=(flag)
                    @model["state"] = flag ? "open" : "closed"
                end

                # @return [Integer]
                def number
                    @model["number"]
                end

                # @return [String]
                def title
                    @model["title"]
                end

                # @return [String]
                def base_branch
                    @model["base"]["ref"]
                end

                # @return [String]
                def head_sha
                    @model["head"]["sha"]
                end

                # @return [Time]
                def updated_at
                    Time.parse(@model["updated_at"])
                end

                # @return [String]
                def body
                    @model["body"]
                end

                # @return [String]
                def web_url
                    @model["html_url"]
                end

                # @return [String]
                def repository_url
                    @model["base"]["repo"]["html_url"]
                end

                # @return [String]
                def author
                    @model["user"]["login"]
                end

                # @return [String]
                def last_committer
                    @model["head"]["user"]["login"]
                end

                # @return [Boolean]
                def draft?
                    @model["draft"]
                end
            end
        end
    end
end
