# frozen_string_literal: true

require "autoproj/daemon/github/branch"
require "test_helper"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Github main module
        module Github
            describe Branch do
                attr_reader :branch
                attr_reader :model

                before do
                    @model = JSON.parse(
                        File.read(File.expand_path("branch.json", __dir__))
                    )

                    @branch = Branch.new("owner", "name", @model)
                end

                it "returns owner" do
                    assert_equal "owner", branch.owner
                end

                it "returns repo name" do
                    assert_equal "name", branch.name
                end

                it "returns branch name" do
                    assert_equal "1.11", branch.branch_name
                end

                it "returns sha" do
                    assert_equal "8076a19fdcab7e1fc1707952d652f0bb6c6db331",
                                 branch.sha
                end

                it "returns the commit author" do
                    assert_equal "The Octocat", branch.commit_author
                end

                it "returns the commit date" do
                    assert_equal Time.parse("2012-03-06T15:06:50-08:00"),
                                 branch.commit_date
                end
            end
        end
    end
end
