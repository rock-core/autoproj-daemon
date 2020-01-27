# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'autoproj/daemon'
require 'autoproj/test'
require 'minitest/autorun'
require 'minitest/spec'
require 'fileutils'
require 'yaml'
require 'octokit'
require 'open3'
require 'rubygems/package'

module Autoproj
    module Daemon
        # Helpers to ease tests
        module TestHelpers
            attr_reader :ws
            attr_reader :installation_manifest

            def autoproj_daemon_create_ws(**vcs)
                @ws = ws_create
                @installation_manifest_path =
                    Autoproj::InstallationManifest.path_for_workspace_root(ws.root_dir)

                @installation_manifest =
                    Autoproj::InstallationManifest.new(@installation_manifest_path)

                installation_manifest.save
                return ws unless vcs

                ws.manifest.vcs = Autoproj::VCSDefinition.from_raw(vcs)
                ws.config.set 'manifest_source', vcs.dup, true
                ws.config.save

                autoproj_daemon_git_init('autoproj', dummy: false)
                ws
            end

            def autoproj_daemon_mock_github_api
                @mock_client = flexmock(Octokit::Client).new_instances
                @mock_rate_limit = flexmock

                @mock_client.should_receive(:rate_limit).and_return { @mock_rate_limit }
                @mock_client.should_receive(:rate_limit!).and_return { @mock_rate_limit }
                @mock_rate_limit
                    .should_receive(:remaining)
                    .and_return { @client_rate_limit_remaining }

                @mock_client
                    .should_receive(:pull_requests)
                    .and_return do |repo, _options|
                        @client_pull_requests[repo] || []
                    end

                @mock_client
                    .should_receive(:pull_request)
                    .and_return do |repo, number, _options|
                        (@client_pull_requests[repo] || [])
                            .find { |pr| pr['number'] == number }
                    end

                @mock_client
                    .should_receive(:branches)
                    .and_return do |repo, _options|
                        @client_branches[repo] || []
                    end

                @mock_client
                    .should_receive(:user)
                    .and_return do |user|
                        @client_users[user] || {}
                    end

                @mock_client
                    .should_receive(:user_events)
                    .and_return do |user|
                        @client_user_events[user] || []
                    end

                @mock_client
                    .should_receive(:organization_events)
                    .and_return do |organization|
                        @client_organization_events[organization] || []
                    end

                @client_rate_limit_remaining = 1000
                @client_pull_requests = {}
                @client_branches = {}
                @client_users = {}
                @client_organization_events = {}
                @client_user_events = {}
            end

            def autoproj_daemon_run_git(*args)
                _, err, status = Open3.capture3('git', *args)
                raise err unless status.success?
            end

            def autoproj_daemon_git_init(dir, dummy: true)
                dir = File.join(@ws.root_dir, dir)
                FileUtils.mkdir_p dir if dummy

                Dir.chdir(dir) do
                    FileUtils.touch(File.join(dir, 'dummy')) if dummy

                    autoproj_daemon_run_git('init')
                    autoproj_daemon_run_git('remote', 'add', 'autobuild', dir)
                    autoproj_daemon_run_git('add', '.')
                    autoproj_daemon_run_git('commit', '-m', 'Initial commit')
                    autoproj_daemon_run_git('push', '-f', 'autobuild', 'master')
                end
            end

            def save_installation_manifest
                File.write(@installation_manifest_path, YAML.dump(@entries))
            end

            def autoproj_daemon_add_package(name, vcs)
                autoproj_daemon_git_init(name)

                vcs = Autoproj::VCSDefinition.from_raw(vcs)
                entry = {
                    'name' => name,
                    'type' => 'Autobuild::CMake',
                    'vcs' => vcs.to_hash,
                    'srcdir' => File.join(ws.root_dir, name),
                    'importdir' => File.join(ws.root_dir, name),
                    'builddir' => File.join(ws.root_dir, name, 'build'),
                    'logdir' => File.join(ws.prefix_dir, 'log'),
                    'prefix' => ws.prefix_dir,
                    'dependencies' => []
                }

                @entries ||= []
                @entries << entry

                save_installation_manifest
                Autoproj::InstallationManifest::Package.new(
                    entry['name'], entry['type'], entry['vcs'], entry['srcdir'],
                    entry['importdir'], entry['prefix'], entry['builddir'],
                    entry['logdir'], entry['dependencies']
                )
            end

            def autoproj_daemon_define_user(user, **options)
                options = JSON.parse(options.to_json)
                @client_users ||= {}
                @client_users[user] = options
                options
            end

            def autoproj_daemon_add_package_set(name, vcs)
                pkg_set = Autoproj::PackageSet.new(
                    ws,
                    Autoproj::VCSDefinition.from_raw(vcs),
                    name: name
                )

                entry = {
                    'package_set' => pkg_set.name,
                    'vcs' => pkg_set.vcs.to_hash,
                    'raw_local_dir' => pkg_set.raw_local_dir,
                    'user_local_dir' => pkg_set.user_local_dir
                }

                @entries ||= []
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
                event = Autoproj::Daemon::Github::PushEvent.new(
                    repo: {
                        name: "#{options[:owner]}/#{options[:name]}"
                    },
                    payload: {
                        head: options[:head_sha],
                        ref: "refs/heads/#{options[:branch]}"
                    },
                    created_at: options[:created_at]
                )
                return event unless @mock_client

                if @mock_client.user(event.owner)['type'] == 'Organization'
                    @client_orgaization_events ||= {}
                    @client_orgaization_events[event.owner] ||= []
                    @client_orgaization_events[event.owner] << event.model
                else
                    @client_user_events ||= {}
                    @client_user_events[event.owner] ||= []
                    @client_user_events[event.owner] << event.model
                end
                event
            end

            def autoproj_daemon_create_pull_request(options)
                Autoproj::Daemon::Github::PullRequest.new(
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
                    state: options[:state]
                )
                event = Autoproj::Daemon::Github::PullRequestEvent.new(
                    payload: {
                        pull_request: pr.instance_variable_get(:@model)
                    },
                    created_at: options[:created_at]
                )
                return event unless @mock_client

                if @mock_client.user(pr.base_owner)['type'] == 'Organization'
                    @client_orgaization_events ||= {}
                    @client_orgaization_events[pr.base_owner] ||= []
                    @client_orgaization_events[pr.base_owner] << event.model
                else
                    @client_user_events ||= {}
                    @client_user_events[pr.base_owner] ||= []
                    @client_user_events[pr.base_owner] << event.model
                end
                event
            end

            def autoproj_daemon_add_pull_request(**options)
                pr = Autoproj::Daemon::Github::PullRequest.new(
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

                @client_pull_requests ||= {}
                @client_pull_requests["#{pr.base_owner}/#{pr.base_name}"] ||= []
                @client_pull_requests["#{pr.base_owner}/#{pr.base_name}"] << pr.model
                pr
            end

            def autoproj_daemon_add_branch(owner, name, options)
                branch = Autoproj::Daemon::Github::Branch.new(
                    owner, name,
                    name: options[:branch_name],
                    commit: {
                        sha: options[:sha]
                    }
                )

                @client_branches ||= {}
                @client_branches["#{branch.owner}/#{branch.name}"] ||= []
                @client_branches["#{branch.owner}/#{branch.name}"] << branch.model
                branch
            end
        end
    end
end
