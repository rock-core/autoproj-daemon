# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "autoproj/daemon"
require "autoproj/test"
require "minitest/autorun"
require "minitest/spec"
require "fileutils"
require "yaml"
require "octokit"
require "open3"
require "rubygems/package"

module Autoproj
    module Daemon
        # Stores github models
        class GithubStorage
            RateLimit = Struct.new(:remaining)

            attr_reader :rate_limit, :pull_requests, :branches, :users,
                        :organization_events, :user_events

            def initialize
                @rate_limit = RateLimit.new(1000)
                @pull_requests = Hash.new { |h, k| h[k] = [] }
                @branches = Hash.new { |h, k| h[k] = [] }
                @users = Hash.new { |h, k| h[k] = {} }
                @organization_events = Hash.new { |h, k| h[k] = [] }
                @user_events = Hash.new { |h, k| h[k] = [] }
            end
        end

        # The actual Octokit::Client API mock
        module MockClient
            attr_accessor :storage

            def pull_requests(repo, _options = {})
                @storage.pull_requests[repo]
            end

            def pull_request(repo, number, _options = {})
                @storage.pull_requests[repo].find { |pr| pr["number"] == number }
            end

            def branches(repo, _options = {})
                @storage.branches[repo]
            end

            def branch(repo, name, _options = {})
                @storage.branches[repo].find { |branch| branch["name"] == name }
            end

            def user(user, _options = {})
                @storage.users[user]
            end

            def user_events(user, _options = {})
                @storage.user_events[user]
            end

            def organization_events(organization, _options = {})
                @storage.organization_events[organization]
            end

            def rate_limit
                @storage.rate_limit
            end

            def rate_limit!
                @storage.rate_limit
            end
        end

        # Helpers to ease tests
        module TestHelpers
            attr_reader :ws

            def setup
                super
                @storage = GithubStorage.new
            end

            def autoproj_daemon_create_ws(**vcs)
                @installation_manifest = nil
                @installation_manifest_path = nil
                @ws = ws_create
                @entries ||= []

                installation_manifest.save
                return ws unless vcs

                setup_buildconf_vcs(vcs)
                ws
            end

            def installation_manifest
                @installation_manifest ||=
                    Autoproj::InstallationManifest.new(installation_manifest_path)
            end

            def installation_manifest_path
                @installation_manifest_path ||=
                    Autoproj::InstallationManifest.path_for_workspace_root(ws.root_dir)
            end

            def save_installation_manifest
                File.write(installation_manifest_path, YAML.dump(@entries))
            end

            def setup_buildconf_vcs(vcs)
                ws.manifest.vcs = Autoproj::VCSDefinition.from_raw(vcs)
                ws.config.set "manifest_source", vcs.dup, true
                ws.config.save

                autoproj_daemon_git_init("autoproj", dummy: false)
            end

            def autoproj_daemon_mock_github_api
                flexmock(Octokit::Client).new_instances do |i|
                    i.extend MockClient
                    i.storage = @storage
                end
            end

            def autoproj_daemon_run_git(dir, *args)
                _, err, status = Open3.capture3("git", *args, chdir: dir)
                raise err unless status.success?
            end

            def autoproj_daemon_git_init(dir, dummy: true)
                dir = File.join(@ws.root_dir, dir)
                if dummy
                    FileUtils.mkdir_p dir
                    FileUtils.touch(File.join(dir, "dummy"))
                end
                autoproj_daemon_run_git(dir, "init")
                autoproj_daemon_run_git(dir, "remote", "add", "autobuild", dir)
                autoproj_daemon_run_git(dir, "add", ".")
                autoproj_daemon_run_git(dir, "commit", "-m", "Initial commit")
                autoproj_daemon_run_git(dir, "push", "-f", "autobuild", "master")
            end

            def autoproj_daemon_buildconf_package
                @autoproj_daemon_buildconf_package ||= CLI::Daemon.buildconf_package(@ws)
            end

            def autoproj_daemon_add_package(name, vcs)
                autoproj_daemon_git_init(name)

                vcs = Autoproj::VCSDefinition.from_raw(vcs)
                entry = {
                    "name" => name,
                    "type" => "Autobuild::CMake",
                    "vcs" => vcs.to_hash,
                    "srcdir" => File.join(ws.root_dir, name),
                    "importdir" => File.join(ws.root_dir, name),
                    "builddir" => File.join(ws.root_dir, name, "build"),
                    "logdir" => File.join(ws.prefix_dir, "log"),
                    "prefix" => ws.prefix_dir,
                    "dependencies" => []
                }

                @entries << entry

                save_installation_manifest
                Autoproj::InstallationManifest::Package.new(
                    entry["name"],
                    entry["type"],
                    entry["vcs"],
                    entry["srcdir"],
                    entry["importdir"],
                    entry["prefix"],
                    entry["builddir"],
                    entry["logdir"],
                    entry["dependencies"]
                )
            end

            def autoproj_daemon_add_package_repository(
                pkg_name, owner, name, branch = "master"
            )
                pkg = autoproj_daemon_add_package(
                    pkg_name,
                    type: "git",
                    url: "https://github.com/#{owner}/#{name}",
                    branch: branch
                )

                PackageRepository.new(
                    pkg_name, owner, name, pkg.vcs.to_hash,
                    ws: ws, local_dir: pkg.srcdir
                )
            end

            def autoproj_daemon_define_user(user, **options)
                @storage.users[user] = JSON.parse(options.to_json)
            end

            def autoproj_daemon_add_event(owner, model)
                if @storage.users[owner]["type"] == "Organization"
                    @storage.organization_events[owner] << model
                else
                    @storage.user_events[owner] << model
                end
            end

            def autoproj_daemon_add_package_set(name, vcs)
                pkg_set = Autoproj::PackageSet.new(
                    ws,
                    Autoproj::VCSDefinition.from_raw(vcs),
                    name: name
                )

                entry = {
                    "package_set" => pkg_set.name,
                    "vcs" => pkg_set.vcs.to_hash,
                    "raw_local_dir" => pkg_set.raw_local_dir,
                    "user_local_dir" => pkg_set.user_local_dir
                }

                @entries << entry

                save_installation_manifest
                Autoproj::InstallationManifest::PackageSet.new(
                    pkg_set.name,
                    pkg_set.vcs.to_hash,
                    pkg_set.raw_local_dir,
                    pkg_set.user_local_dir
                )
            end

            def autoproj_daemon_add_push_event(**options)
                event = Autoproj::Daemon::Github::PushEvent.from_ruby_hash(
                    repo: {
                        name: "#{options[:owner]}/#{options[:name]}"
                    },
                    payload: {
                        head: options[:head_sha],
                        ref: "refs/heads/#{options[:branch]}"
                    },
                    actor: {
                        login: options[:author]
                    },
                    created_at: options[:created_at] || Time.now
                )

                autoproj_daemon_add_event(event.owner, event.model)
                event
            end

            def autoproj_daemon_create_pull_request(options)
                Autoproj::Daemon::Github::PullRequest.from_ruby_hash(
                    state: options[:state],
                    number: options[:number],
                    title: options[:title],
                    updated_at: options[:updated_at] || Time.now,
                    body: options[:body],
                    base: {
                        ref: options[:base_branch],
                        sha: options[:base_sha],
                        user: {
                            login: options[:base_owner]
                        },
                        repo: {
                            name: options[:base_name]
                        }
                    },
                    head: {
                        ref: options[:head_branch],
                        sha: options[:head_sha],
                        user: {
                            login: options[:head_owner]
                        },
                        repo: {
                            name: options[:head_name]
                        }
                    }
                )
            end

            def autoproj_daemon_add_pull_request_event(**options)
                pr = options[:pull_request] || autoproj_daemon_create_pull_request(
                    base_owner: options[:base_owner],
                    base_name: options[:base_name],
                    base_branch: options[:base_branch],
                    state: options[:state],
                    number: options[:number]
                )
                event = Autoproj::Daemon::Github::PullRequestEvent.from_ruby_hash(
                    payload: {
                        pull_request: pr.instance_variable_get(:@model)
                    },
                    created_at: options[:created_at]
                )

                autoproj_daemon_add_event(pr.base_owner, event.model)
                event
            end

            def autoproj_daemon_add_pull_request(**options)
                pr = Autoproj::Daemon::Github::PullRequest.from_ruby_hash(
                    state: options[:state] || "open",
                    number: options[:number],
                    title: options[:title],
                    updated_at: options[:updated_at] || Time.now,
                    body: options[:body],
                    base: {
                        ref: options[:base_branch],
                        sha: options[:base_sha],
                        user: {
                            login: options[:base_owner]
                        },
                        repo: {
                            name: options[:base_name]
                        }
                    },
                    head: {
                        ref: options[:head_branch],
                        sha: options[:head_sha],
                        user: {
                            login: options[:head_owner]
                        },
                        repo: {
                            name: options[:head_name]
                        }
                    }
                )

                @storage.pull_requests["#{pr.base_owner}/#{pr.base_name}"] << pr.model
                pr
            end

            def autoproj_daemon_add_branch(owner, name, options)
                branch = Autoproj::Daemon::Github::Branch.from_ruby_hash(
                    owner, name,
                    name: options[:branch_name],
                    commit: {
                        sha: options[:sha]
                    }
                )

                @storage.branches["#{branch.owner}/#{branch.name}"] << branch.model
                branch
            end
        end
    end
end
