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
                    attr_reader :pr0, :pr1, :pr2

                    before do
                        @pr0 = PullRequest.new("0", {})
                        @pr0.dependencies = []
                        @pr1 = PullRequest.new("1", {})
                        @pr1.dependencies = []
                        @pr2 = PullRequest.new("2", {})
                        @pr2.dependencies = []
                    end

                    it "returns the direct dependencies" do
                        pr0.dependencies = [pr1, pr2]

                        assert_equal Set[pr1, pr2], pr0.recursive_dependencies.to_set
                        assert_equal Set[], pr1.recursive_dependencies.to_set
                        assert_equal Set[], pr2.recursive_dependencies.to_set
                    end

                    it "returns the dependencies of dependencies" do
                        pr0.dependencies = [pr1]
                        pr1.dependencies = [pr2]

                        assert_equal Set[pr1, pr2], pr0.recursive_dependencies.to_set
                        assert_equal Set[pr2], pr1.recursive_dependencies.to_set
                        assert_equal Set[], pr2.recursive_dependencies.to_set
                    end

                    it "handles cycles in the pull requests dependencies" do
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
