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
            attr_reader :pull_requests, :branches

            def initialize
                @pull_requests = Hash.new { |h, k| h[k] = [] }
                @branches = Hash.new { |h, k| h[k] = [] }
                @users = Hash.new { |h, k| h[k] = {} }
            end
        end

        # The actual Octokit::Client API mock
        module MockClient
            attr_accessor :storage

            def pull_requests(repo, _options = {})
                repo = GitAPI::URL.new(repo)
                @storage.pull_requests[repo].dup
            end

            def branches(repo, _options = {})
                repo = GitAPI::URL.new(repo)
                @storage.branches[repo].dup
            end

            def branch(repo, name, _options = {})
                repo = GitAPI::URL.new(repo)
                @storage.branches[repo].find { |branch| branch.branch_name == name }
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

            def autoproj_daemon_mock_git_api
                flexmock(GitAPI::Client).new_instances do |i|
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
                pkg_name, url, branch = "master"
            )
                pkg = autoproj_daemon_add_package(
                    pkg_name,
                    type: "git",
                    url: url,
                    branch: branch
                )

                PackageRepository.new(
                    pkg_name, pkg.vcs.to_hash,
                    ws: ws, local_dir: pkg.srcdir
                )
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

            def autoproj_daemon_create_pull_request(**options)
                git_url = Autoproj::Daemon::GitAPI::URL.new(options[:repo_url])
                Autoproj::Daemon::GitAPI::PullRequest.from_ruby_hash(
                    git_url,
                    state: options[:state],
                    number: options[:number],
                    title: options[:title],
                    updated_at: options[:updated_at] || Time.now,
                    body: options[:body],
                    html_url: "https://#{git_url.full_path}/pull/#{options[:number]}",
                    draft: options[:draft],
                    user: {
                        login: options[:author]
                    },
                    base: {
                        ref: options[:base_branch],
                        sha: options[:base_sha],
                        repo: {
                            html_url: "https://#{git_url.full_path}"
                        }
                    },
                    head: {
                        sha: options[:head_sha],
                        user: {
                            login: options[:last_committer]
                        }
                    }
                )
            end

            def autoproj_daemon_add_pull_request(**options)
                git_url = Autoproj::Daemon::GitAPI::URL.new(options[:repo_url])
                pr = autoproj_daemon_create_pull_request(**options)
                @storage.pull_requests[git_url] << pr
                pr
            end

            def autoproj_daemon_create_branch(**options)
                git_url = Autoproj::Daemon::GitAPI::URL.new(options[:repo_url])
                Autoproj::Daemon::GitAPI::Branch.from_ruby_hash(
                    git_url,
                    repository_url: "https://#{git_url.full_path}",
                    name: options[:branch_name],
                    commit: {
                        sha: options[:sha],
                        commit: {
                            author: {
                                name: options[:commit_author],
                                date: options[:commit_date]
                            }
                        }
                    }
                )
            end

            def autoproj_daemon_add_branch(**options)
                git_url = Autoproj::Daemon::GitAPI::URL.new(options[:repo_url])
                branch = autoproj_daemon_create_branch(**options)
                @storage.branches[git_url] << branch
                branch
            end
        end
    end
end
