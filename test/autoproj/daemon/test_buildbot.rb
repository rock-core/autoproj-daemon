# frozen_string_literal: true

require "test_helper"
require "autoproj/daemon/buildbot"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        describe Buildbot do
            attr_reader :bb
            attr_reader :ws

            include Autoproj::Daemon::TestHelpers
            before do
                @ws = ws_create
                @bb = Buildbot.new(ws, project: "wetpaint")
            end

            describe "#uri" do
                it "formats buildbot url endpoint" do
                    ws.config.daemon_buildbot_host = "bb-master"
                    ws.config.daemon_buildbot_port = 8666

                    assert_equal URI.parse(
                        "http://bb-master:8666/change_hook/base"
                    ), bb.uri
                end
            end

            describe "#build" do
                it "returns true if command is accepted" do
                    Timecop.freeze
                    ws.config.daemon_buildbot_host = "bb-master"
                    ws.config.daemon_buildbot_port = 8666

                    response = flexmock
                    response.should_receive(code: "200")

                    options = {
                        "author" => "",
                        "branch" => "master",
                        "codebase" => "",
                        "category" => "",
                        "comments" => "",
                        "committer" => "",
                        "project" => "wetpaint",
                        "repository" => "",
                        "revision" => "",
                        "revlink" => "",
                        "when_timestamp" => Time.now.to_s,
                        "properties" => {
                            package_names: ["foobar"],
                            source_branch: "feature",
                            source_project_id: 1
                        }.to_json
                    }

                    flexmock(Net::HTTP)
                        .new_instances
                        .should_receive("request").and_return do |request|
                            assert_equal options, URI.decode_www_form(request.body).to_h
                            response
                        end

                    assert bb.post_change(
                        package_names: ["foobar"],
                        source_branch: "feature",
                        source_project_id: 1
                    )
                end
                it "returns false if command fails" do
                    ws.config.daemon_buildbot_host = "bb-master"
                    ws.config.daemon_buildbot_port = 8666

                    response = flexmock
                    response.should_receive(code: "404", body: "some error")

                    flexmock(Net::HTTP)
                        .new_instances
                        .should_receive("request")
                        .and_return(response)

                    refute bb.post_change
                end
                it "returns false if the request fails because of network errors" do
                    ws.config.daemon_buildbot_host = "bb-master"
                    ws.config.daemon_buildbot_port = 8666

                    flexmock(Net::HTTP)
                        .new_instances
                        .should_receive("request")
                        .and_raise(Errno::ECONNREFUSED)

                    refute bb.post_change
                end
            end
            describe "#post_pull_request_changes" do
                it "adds buildbot force build paramaters" do
                    now = Time.now
                    flexmock(bb).should_receive(:post_change).with(
                        package_names: ["foobar"],
                        author: "author",
                        branch: "autoproj/wetpaint/github.com/"\
                                "tidewise/drivers-gps_ublox/pulls/22",
                        source_branch: "feature",
                        category: "pull_request",
                        codebase: "",
                        committer: "contributor",
                        source_project_id: 10,
                        repository: "https://github.com/tidewise/drivers-gps_ublox",
                        revision: "abcdef",
                        revlink: "https://github.com/tidewise/drivers-gps_ublox/pull/22",
                        when_timestamp: now.tv_sec
                    ).once

                    pr = autoproj_daemon_add_pull_request(
                        repo_url: "git@github.com:tidewise/drivers-gps_ublox.git",
                        number: 22,
                        base_branch: "master",
                        head_branch: "feature",
                        head_repo_id: 10,
                        last_committer: "contributor",
                        author: "author",
                        head_sha: "abcdef",
                        updated_at: now
                    )

                    bb.post_pull_request_changes(pr, package_names: ["foobar"])
                end
            end
            describe "#post_mainline_changes" do
                it "adds buildbot force build paramaters" do
                    now = Time.now
                    flexmock(bb).should_receive(:post_change).with(
                        package_names: ["foobar"],
                        author: "g-arjones",
                        branch: "main",
                        source_branch: "devel",
                        category: "push",
                        codebase: "",
                        committer: "g-arjones",
                        repository: "https://github.com/tidewise/drivers-gps_ublox",
                        revision: "abcdef",
                        revlink: "https://github.com/tidewise/drivers-gps_ublox",
                        when_timestamp: now.tv_sec
                    ).once

                    branch = autoproj_daemon_add_branch(
                        repo_url: "git@github.com:tidewise/drivers-gps_ublox.git",
                        branch_name: "devel",
                        sha: "abcdef",
                        commit_author: "g-arjones",
                        commit_date: now
                    )

                    package = flexmock
                    package.should_receive(:package).and_return("foobar")
                    bb.post_mainline_changes(package, branch, buildconf_branch: "main")
                end
            end
        end
    end
end
