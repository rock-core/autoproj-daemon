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

                ws.config.daemon_set_service("github.com", "apikey")
                ws.config.save

                @updater = Autoproj::Daemon::WorkspaceUpdater.new(ws)
                @cli = Daemon.new(ws, @updater)
            end

            describe "#prepare" do
                it "does not allow non-git buildconfs" do
                    autoproj_daemon_create_ws(type: "none")
                    @updater = Autoproj::Daemon::WorkspaceUpdater.new(ws)
                    @cli = Daemon.new(ws, @updater)
                    e = assert_raises(Autoproj::ConfigError) do
                        @cli.prepare
                    end
                    assert_match(/should be under git/, e.message)
                end

                it "does not allow buildconfs hosted on unsupported services" do
                    autoproj_daemon_create_ws(
                        type: "git",
                        url: "git@dummy.com:rock-core/buildconf"
                    )

                    @updater = Autoproj::Daemon::WorkspaceUpdater.new(ws)
                    @cli = Daemon.new(ws, @updater)
                    e = assert_raises(Autoproj::ConfigError) do
                        @cli.prepare
                    end
                    assert_match(/dummy.com, which is either/, e.message)
                end

                it "allows supported git services" do
                    @cli.prepare
                    assert @cli.buildconf_package.buildconf?
                    assert_equal "git@github.com:rock-core/buildconf",
                                 @cli.buildconf_package.repo_url
                end
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
            it "raises if project name is invalid" do
                ws.config.set "daemon_project", "foo/", true
                assert_raises(Autoproj::ConfigError) do
                    Daemon.new(ws, @updater, load_config: false)
                end

                ws.config.set "daemon_project", "foo*", true
                assert_raises(Autoproj::ConfigError) do
                    Daemon.new(ws, @updater, load_config: false)
                end

                ws.config.set "daemon_project", "foo ", true
                assert_raises(Autoproj::ConfigError) do
                    Daemon.new(ws, @updater, load_config: false)
                end
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

            describe "#packages" do
                it "ignores packages that do not have a valid vcs" do
                    autoproj_daemon_add_package(
                        "foo",
                        type: "git",
                        url: "https://dummy.com/owner/foo",
                        remote_branch: "develop"
                    )
                    autoproj_daemon_add_package("bar", type: "none")
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
                                url: "git://github.com/rock-core/package_set",
                                remote_branch: "develop"
                    )

                    pkg_set = cli.packages.first
                    assert_equal "git://github.com/rock-core/package_set",
                                 pkg_set.repo_url

                    assert_equal "rock", pkg_set.package
                    assert pkg_set.package_set?
                end
                it "properly handles packages" do
                    autoproj_daemon_add_package(
                        "tools/roby", type: "git",
                                      url: "git://github.com/rock-core/tools-roby",
                                      master: "master"
                    )

                    pkg = cli.packages.first
                    assert_equal "git://github.com/rock-core/tools-roby", pkg.repo_url
                    assert_equal "tools/roby", pkg.package
                    refute pkg.package_set?
                end
            end

            describe "#configure" do
                it "configures daemon" do
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
