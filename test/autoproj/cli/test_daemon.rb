# frozen_string_literal: true

require "test_helper"
require "autoproj/cli/update"
require "autoproj/daemon/package_repository"
require "autoproj/daemon/workspace_updater"
require "octokit"
require "rubygems/package"
require "time"

module Autoproj
    # Autoproj's main CLI module
    module CLI
        describe Daemon do
            attr_reader :cli

            include Autoproj::Daemon::TestHelpers

            before do
                autoproj_daemon_create_ws(
                    type: "git",
                    url: "git@github.com:rock-core/buildconf"
                )

                @updater = Autoproj::Daemon::WorkspaceUpdater.new(ws)
                @cli = Daemon.new(ws, @updater)
            end

            it "sets the project to 'daemon' if none is given" do
                assert_equal "daemon", @cli.bb.project
                ws.config.set "daemon_api_key", "something", true
                @cli.prepare
                assert_equal "daemon", @cli.bb.project
            end

            it "computes the buildbot project name from the configuration" do
                ws.config.set "daemon_project", "somename", true
                cli = Daemon.new(ws, @updater, load_config: false)
                assert_equal "somename", cli.bb.project
                ws.config.set "daemon_api_key", "something", true
                cli.prepare
                assert_equal "somename", cli.git_poller.bb.project
            end

            it "appends the manifest name if it is not mainline" do
                ws.config.set "daemon_project", "somename", true
                ws.config.set "manifest_name", "manifest.subsystem"
                cli = Daemon.new(ws, @updater, load_config: false)
                assert_equal "somename_subsystem", cli.bb.project
                ws.config.set "daemon_api_key", "something", true
                cli.prepare
                assert_equal "somename_subsystem", cli.git_poller.bb.project
            end
            describe "#resolve_packages" do
                it "returns an array of all packages and package sets" do
                    pkgs = []
                    pkgs << autoproj_daemon_add_package(
                        "foo",
                        type: "git",
                        url: "https://github.com/owner/foo",
                        remote_branch: "develop"
                    )

                    pkgs << autoproj_daemon_add_package(
                        "bar",
                        type: "git",
                        url: "https://github.com/owner/bar",
                        remote_branch: "master"
                    )

                    pkgs << autoproj_daemon_add_package_set(
                        "core",
                        type: "git",
                        url: "https://github.com/owner/core",
                        remote_branch: "master"
                    )

                    pkgs << autoproj_daemon_add_package_set(
                        "utils",
                        type: "git",
                        url: "https://github.com/owner/utils",
                        remote_branch: "master"
                    )
                    assert_equal pkgs, cli.resolve_packages
                end
            end

            describe "#parse_repo_url_from_vcs" do
                it "parses an http url" do
                    owner, name = Daemon.parse_repo_url_from_vcs(
                        type: "git",
                        url: "http://github.com/rock-core/autoproj"
                    )
                    assert_equal "rock-core", owner
                    assert_equal "autoproj", name
                end

                it "parses a ssh url" do
                    owner, name = Daemon.parse_repo_url_from_vcs(
                        type: "git",
                        url: "git@github.com:rock-core/autoproj"
                    )
                    assert_equal "rock-core", owner
                    assert_equal "autoproj", name
                end

                it "removes git extension from repo name" do
                    owner, name = Daemon.parse_repo_url_from_vcs(
                        type: "git",
                        url: "git@github.com:rock-core/autoproj.git"
                    )
                    assert_equal "rock-core", owner
                    assert_equal "autoproj", name
                end

                it "returns nil for incomplete urls" do
                    assert_nil Daemon.parse_repo_url_from_vcs(
                        type: "git",
                        url: "git@github.com:rock-core/"
                    )
                end

                it "returns nil if vcs type is not git" do
                    assert_nil Daemon.parse_repo_url_from_vcs(
                        type: "archive",
                        url: "http://github.com/rock-core/autoproj/release/autoproj-2.1.tgz"
                    )
                end
                it "allows only github urls" do
                    assert_nil Daemon.parse_repo_url_from_vcs(
                        type: "git",
                        url: "git@bitbucket.org:rock-core/autoproj"
                    )
                    assert_nil Daemon.parse_repo_url_from_vcs(
                        type: "git",
                        url: "http://bitbucket.org:rock-core/autoproj"
                    )
                end
            end

            describe "#packages" do
                it "ignores packages that do not have a valid vcs" do
                    autoproj_daemon_add_package(
                        "foo",
                        type: "git",
                        url: "https://gitlab.org/owner/foo",
                        remote_branch: "develop"
                    )
                    assert cli.packages.empty?
                end
                it "ignores packages with frozen commits" do
                    autoproj_daemon_add_package(
                        "foo",
                        type: "git",
                        url: "https://github.com/owner/foo",
                        branch: "master",
                        tag: "1.0"
                    )

                    autoproj_daemon_add_package(
                        "bar",
                        type: "git",
                        url: "https://github.com/owner/bar",
                        branch: "master",
                        commit: "abcdef"
                    )

                    assert cli.packages.empty?
                end
                it "properly handles package sets" do
                    autoproj_daemon_add_package_set(
                        "rock", type: "git",
                                url: "https://github.com/rock-core/package_set",
                                remote_branch: "develop"
                    )

                    pkg_set = cli.packages.first
                    assert_equal "rock-core", pkg_set.owner
                    assert_equal "package_set", pkg_set.name
                    assert_equal "rock", pkg_set.package
                    assert pkg_set.package_set?
                end
                it "properly handles packages" do
                    autoproj_daemon_add_package(
                        "tools/roby", type: "git",
                                      url: "https://github.com/rock-core/tools-roby",
                                      master: "master"
                    )

                    pkg = cli.packages.first
                    assert_equal "rock-core", pkg.owner
                    assert_equal "tools-roby", pkg.name
                    assert_equal "tools/roby", pkg.package
                    refute pkg.package_set?
                end
            end

            describe "#configure" do
                it "configures daemon" do
                    flexmock(ws.config)
                        .should_receive(:configure).with("daemon_api_key").once
                    flexmock(ws.config)
                        .should_receive(:configure).with("daemon_polling_period")
                        .at_least.once
                    flexmock(ws.config)
                        .should_receive(:configure).with("daemon_buildbot_host")
                        .at_least.once
                    flexmock(ws.config)
                        .should_receive(:configure).with("daemon_buildbot_port")
                        .at_least.once
                    flexmock(ws.config)
                        .should_receive(:configure).with("daemon_project")
                        .at_least.once
                    flexmock(ws.config)
                        .should_receive(:configure).with("daemon_max_age")
                        .at_least.once
                    cli.configure
                end
            end
        end
    end
end
