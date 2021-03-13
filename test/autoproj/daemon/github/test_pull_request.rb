# frozen_string_literal: true

require "autoproj/daemon/github/pull_request"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Github main module
        module Github
            describe PullRequest do
                attr_reader :pull_request
                attr_reader :model

                before do
                    @model = JSON.parse(
                        File.read(File.expand_path("pull_request.json", __dir__))
                    )

                    @pull_request = PullRequest.new(@model)
                end

                it "returns true if open" do
                    assert pull_request.open?
                end

                it "returns false if closed" do
                    @model["state"] = "closed"
                    @pull_request = PullRequest.new(@model)

                    refute pull_request.open?
                end

                it "returns the number" do
                    assert_equal 81_609, pull_request.number
                end

                it "returns the title" do
                    assert_equal "Save all and commit fix", pull_request.title
                end

                it "returns the base branch" do
                    assert_equal "master", pull_request.base_branch
                end

                it "returns the head branch" do
                    assert_equal "saveAllAndCommitFix", pull_request.head_branch
                end

                it "returns the head sha" do
                    assert_equal "6a0c40a0cc4edd4b5c9e520be86ac0c5c4402dd9",
                                 pull_request.head_sha
                end

                it "returns the base owner" do
                    assert_equal "microsoft", pull_request.base_owner
                end

                it "returns the head owner" do
                    assert_equal "vedipen", pull_request.head_owner
                end

                it "returns the base repo name" do
                    assert_equal "vscode", pull_request.base_name
                end

                it "returns the head repo name" do
                    assert_equal "vscode", pull_request.head_name
                end

                it "returns nil if head repo is nil" do
                    @model = @pull_request.instance_variable_get(:@model)
                    @model["head"]["repo"] = nil
                    assert_nil pull_request.head_name
                end

                it "returns the pull request body" do
                    assert_equal "Faced the same issue #80837 "\
                        "and didn't see much activity.\r\nThis PR fixes #80837 ",
                                 pull_request.body
                end
            end
        end
    end
end
