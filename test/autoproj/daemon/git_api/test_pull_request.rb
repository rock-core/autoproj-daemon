# frozen_string_literal: true

require "autoproj/daemon/git_api/client"
require "test_helper"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # :nodoc:
        module GitAPI
            describe PullRequest do
                describe "#recursive_dependencies" do
                    it "handles cycles in the pull requests dependencies" do
                        pr0 = PullRequest.new("", {})
                        pr1 = PullRequest.new("", {})
                        pr2 = PullRequest.new("", {})

                        pr0.dependencies = [pr1, pr2]
                        pr1.dependencies = [pr2]
                        pr2.dependencies = [pr0]

                        assert_equal Set[pr1, pr2], pr0.recursive_dependencies.to_set
                        assert_equal Set[pr0, pr2], pr1.recursive_dependencies.to_set
                        assert_equal Set[pr0, pr1], pr2.recursive_dependencies.to_set
                    end
                end
            end
        end
    end
end
