# frozen_string_literal: true

require "autoproj/daemon/git_api/client"
require "test_helper"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Git API main module
        module GitAPI
            describe Client do
                include Autoproj::Daemon::TestHelpers
                attr_reader :gitlabmock, :client, :url, :branch_model, :pr_model

                let(:client) { Client.new(ws) }
                before do
                    autoproj_daemon_create_ws(
                        type: "git",
                        url: "git@gitlab.com:rock-core/buildconf"
                    )
                    ws.config.daemon_set_service("gitlab.com", "apikey")

                    @url = "git@gitlab.com:rock-core/buildconf"
                    @gitlabmock = flexmock(Gitlab::Client).new_instances
                end

                def assert_transforms(from, to, *args)
                    assert_raises(to) do
                        client.service(url).exception_adapter { raise from, *args }
                    end
                end

                it "transforms exceptions" do
                    assert_transforms(Errno::ECONNREFUSED, GitAPI::ConnectionFailed, "")
                    assert_transforms(Net::ReadTimeout, GitAPI::ConnectionFailed, "")
                    assert_transforms(EOFError, GitAPI::ConnectionFailed, "")
                    assert_transforms(Errno::ECONNRESET, GitAPI::ConnectionFailed, "")
                    assert_transforms(Errno::ECONNABORTED, GitAPI::ConnectionFailed, "")
                    assert_transforms(Errno::EPIPE, GitAPI::ConnectionFailed, "")
                end

                describe "branch data" do
                    before do
                        @branch_model = JSON.parse(
                            File.read(File.expand_path("gitlab_branch.json", __dir__))
                        )
                        @branch_model = Gitlab::ObjectifiedHash.new(@branch_model)

                        gitlabmock.should_receive(:branch)
                                  .with("rock-core/buildconf", "master")
                                  .and_return(branch_model)

                        pagination = flexmock
                        pagination.should_receive(:auto_paginate)
                                  .and_return([@branch_model])
                        gitlabmock.should_receive(:branches)
                                  .with("rock-core/buildconf")
                                  .and_return(pagination)
                    end

                    it "stores repo url" do
                        branch = client.branch(url, "master")
                        assert branch.git_url.same?(url)
                    end

                    it "returns branch name" do
                        branch = client.branch(url, "master")
                        assert_equal "master", branch.branch_name
                    end

                    it "returns sha" do
                        branch = client.branch(url, "master")
                        assert_equal "7b5c3cc8be40ee161ae89a06bba6229da1032a0c",
                                     branch.sha
                    end

                    it "returns the commit author" do
                        branch = client.branch(url, "master")
                        assert_equal "John Smith", branch.commit_author
                    end

                    it "returns the commit date" do
                        branch = client.branch(url, "master")
                        assert_equal Time.parse("2012-06-28T03:44:20-07:00"),
                                     branch.commit_date
                    end

                    it "returns an array of branches" do
                        branches = client.branches(url)
                        assert_equal 1, branches.size
                        assert_equal Branch, branches.first.class
                    end

                    it "returns the repository web url" do
                        branch = client.branch(url, "master")
                        assert_equal "https://gitlab.com/rock-core/buildconf",
                                     branch.repository_url
                    end
                end

                describe "#extract_info_from_pull_request_ref" do
                    attr_reader :pr

                    before do
                        @pr = autoproj_daemon_create_pull_request(
                            repo_url: "git@gitlab.com:project/"\
                                      "g-arjones._1/demo.pkg_1.git",
                            number: 22
                        )
                    end

                    it "returns info when given a url" do
                        info = ["https://gitlab.com/project/g-arjones._1/demo.pkg_1", 22]
                        assert_equal info, client.extract_info_from_pull_request_ref(
                            "https://gitlab.com/project/"\
                            "g-arjones._1/demo.pkg_1/merge_requests/22", pr
                        )
                    end
                    it "returns info when given a url with subgroups" do
                        info = [
                            "https://gitlab.com/project/g-arjones._1/"\
                            "group1/group2/demo.pkg_1", 22
                        ]
                        assert_equal info, client.extract_info_from_pull_request_ref(
                            "https://gitlab.com/project/g-arjones._1/"\
                            "group1/group2/demo.pkg_1/-/"\
                            "merge_requests/22", pr
                        )
                    end
                    it "returns info when given a full path" do
                        info = ["https://gitlab.com/project/g-arjones._1/demo.pkg_2", 22]
                        assert_equal info, client.extract_info_from_pull_request_ref(
                            "project/g-arjones._1/demo.pkg_2!22", pr
                        )
                    end
                    it "returns info when given a relative path" do
                        info = ["https://gitlab.com/project/g-arjones._1/demo.pkg_2", 22]
                        assert_equal info, client.extract_info_from_pull_request_ref(
                            "demo.pkg_2!22", pr
                        )
                    end
                    it "returns info when given a short ref" do
                        info = ["https://gitlab.com/project/g-arjones._1/demo.pkg_1", 22]
                        assert_equal info, client.extract_info_from_pull_request_ref(
                            "!22", pr
                        )
                    end
                    it "returns nil when ref's scheme is not http" do
                        assert_nil client.extract_info_from_pull_request_ref(
                            "ftp://gitlab.com/project/"\
                            "g-arjones._1/grouṕ1/group2/demo.pkg_1/-/"\
                            "merge_requests/22", pr
                        )
                    end
                    it "returns nil when the item does not look like a PR ref" do
                        assert_nil client.extract_info_from_pull_request_ref(
                            "Feature", pr
                        )
                    end
                end

                describe "pull request data" do
                    before do
                        @pr_model = JSON.parse(
                            File.read(
                                File.expand_path("gitlab_merge_request.json", __dir__)
                            )
                        )
                        @pr_model = Gitlab::ObjectifiedHash.new(@pr_model)
                        pagination = flexmock
                        pagination.should_receive(:auto_paginate)
                                  .and_return { [@pr_model] }
                        gitlabmock.should_receive(:merge_requests)
                                  .with("rock-core/buildconf", any)
                                  .and_return(pagination)
                    end

                    it "stores repo url" do
                        pull_request = client.pull_requests(url).first
                        assert pull_request.git_url.same?(url)
                    end

                    it "returns true if open" do
                        pull_request = client.pull_requests(url).first
                        assert pull_request.open?
                    end

                    it "returns false if closed" do
                        @pr_model = pr_model.to_hash
                        @pr_model["state"] = "closed"
                        @pr_model = Gitlab::ObjectifiedHash.new(pr_model)

                        pull_request = client.pull_requests(url).first
                        refute pull_request.open?
                    end

                    it "returns the number" do
                        pull_request = client.pull_requests(url).first
                        assert_equal 1, pull_request.number
                    end

                    it "returns the title" do
                        pull_request = client.pull_requests(url).first
                        assert_equal "test1", pull_request.title
                    end

                    it "returns the base branch" do
                        pull_request = client.pull_requests(url).first
                        assert_equal "master", pull_request.base_branch
                    end

                    it "returns the head sha" do
                        pull_request = client.pull_requests(url).first
                        assert_equal "8888888888888888888888888888888888888888",
                                     pull_request.head_sha
                    end

                    it "returns the pull request body" do
                        pull_request = client.pull_requests(url).first
                        assert_equal "fixed login page css paddings",
                                     pull_request.body
                    end

                    it "returns the pull request url" do
                        pull_request = client.pull_requests(url).first
                        assert_equal "http://gitlab.example.com/"\
                                     "my-group/my-project/merge_requests/1",
                                     pull_request.web_url
                    end

                    it "returns the base repository url" do
                        pull_request = client.pull_requests(url).first
                        assert_equal "https://gitlab.com/rock-core/buildconf",
                                     pull_request.repository_url
                    end

                    it "returns the pull request author" do
                        pull_request = client.pull_requests(url).first
                        assert_equal "admin", pull_request.author
                    end

                    it "returns the last commit author" do
                        pull_request = client.pull_requests(url).first
                        assert_equal "", pull_request.last_committer
                    end

                    it "returns the draft status" do
                        pull_request = client.pull_requests(url).first
                        refute pull_request.draft?
                        assert_equal "refs/merge-requests/1/merge",
                                     client.test_branch_name(pull_request)

                        @pr_model = pr_model.to_hash
                        @pr_model["work_in_progress"] = true
                        @pr_model = Gitlab::ObjectifiedHash.new(pr_model)
                        pull_request = client.pull_requests(url).first
                        assert pull_request.draft?
                        assert_equal "refs/merge-requests/1/head",
                                     client.test_branch_name(pull_request)
                    end

                    it "returns the mergeable status" do
                        pull_request = client.pull_requests(url).first
                        assert pull_request.mergeable?
                        assert_equal "refs/merge-requests/1/merge",
                                     client.test_branch_name(pull_request)

                        @pr_model = pr_model.to_hash
                        @pr_model["merge_status"] = "cannot_be_merged"
                        @pr_model = Gitlab::ObjectifiedHash.new(pr_model)
                        pull_request = client.pull_requests(url).first
                        refute pull_request.mergeable?
                        assert_equal "refs/merge-requests/1/head",
                                     client.test_branch_name(pull_request)
                    end
                end
            end
        end
    end
end
