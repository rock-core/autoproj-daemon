# frozen_string_literal: true

require "autoproj"
require "net/http"
require "uri"
require "json"
require "autoproj/daemon/github/pull_request"

module Autoproj
    module Daemon
        # Buildbot integration class
        class Buildbot
            # @return [Autoproj::Workspace]
            attr_reader :ws

            # The project name as defined by Buildbot
            #
            # In buildbot, a project is an encompassing concept that regroups
            # multiple repositories/codebases
            #
            # @return [String]
            attr_reader :project

            # @param [Autoproj::Workspace] workspace
            def initialize(workspace, project: "")
                @ws = workspace
                @project = project
            end

            # @param [Hash] options
            # @return [Hash]
            def body(**options)
                BODY.merge(
                    params: BODY[:params].merge(branch: "master").merge(**options)
                )
            end

            # @return [URI]
            def uri
                URI.parse(
                    "http://#{ws.config.daemon_buildbot_host}:"\
                        "#{ws.config.daemon_buildbot_port}/"\
                        "change_hook/base"
                )
            end

            # Publish a change indicating that a pull request was modified
            #
            # @param [Github::PullRequest] pull_request
            # @return [Boolean] true if the posting was successful, false otherwise
            def post_pull_request_changes(pull_request)
                base_repository =
                    "https://github.com/#{pull_request.base_owner}/"\
                    "#{pull_request.base_name}"
                branch_name = GitPoller.branch_name_by_pull_request(
                    @project, pull_request
                )

                post_change(
                    author: pull_request.head_owner,
                    branch: branch_name,
                    category: "pull_request",
                    codebase: "",
                    committer: pull_request.head_owner,
                    repository: base_repository,
                    revision: pull_request.head_sha,
                    revlink: "#{base_repository}/pull/#{pull_request.number}",
                    when_timestamp: pull_request.updated_at.tv_sec
                )
            end

            # Publish changes that happened to a mainline branch
            #
            # @param [PackageRepository] _package
            # @param [Github::Branch] remote_branch
            # @return [Boolean]
            def post_mainline_changes(_package, remote_branch)
                repository =
                    "https://github.com/#{remote_branch.owner}/#{remote_branch.name}"

                post_change(
                    # Codebase is a single codebase - i.e. single repo, but
                    # tracked across forks
                    author: remote_branch.commit_author,
                    branch: remote_branch.branch_name,
                    category: "push",
                    codebase: "",
                    committer: remote_branch.commit_author,
                    repository: repository,
                    revision: remote_branch.sha,
                    revlink: repository,
                    when_timestamp: remote_branch.commit_date.tv_sec
                )
            end

            # @return [Boolean]
            def post_change(
                author: "",
                branch: "master",
                category: "",
                codebase: "",
                comments: "",
                committer: "",
                project: @project,
                repository: "",
                revision: "",
                revlink: "",
                when_timestamp: Time.now
            )
                http = Net::HTTP.new(uri.host, uri.port)
                request = Net::HTTP::Post.new(uri.request_uri)

                options = {
                    author: author,
                    branch: branch,
                    codebase: codebase,
                    category: category,
                    comments: comments,
                    committer: committer,
                    project: project,
                    repository: repository,
                    revision: revision,
                    revlink: revlink,
                    when_timestamp: when_timestamp
                }
                Autoproj.message options.to_s
                request.set_form_data(options)

                Autoproj.message "Triggering build on #{branch}"

                response =
                    begin
                        http.request(request)
                    rescue SystemCallError => e
                        Autoproj.error "Failed to connect to buildbot: #{e}"
                        return false
                    end

                if response.code == "200"
                    Autoproj.message "OK"
                    return true
                end

                Autoproj.error "#{response.code}: #{response.body}"
                false
            end
        end
    end
end
