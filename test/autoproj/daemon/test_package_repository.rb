# frozen_string_literal: true

require "autoproj/daemon/package_repository"
require "test_helper"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        describe PackageRepository do
            attr_reader :package
            attr_reader :ws

            before do
                @ws = ws_create
                @package = PackageRepository.new(
                    "drivers/iodrivers_base",
                    { type: "git", url: "git://github.com/drivers-iodrivers_base" },
                    ws: ws
                )
            end

            describe "#autobuild" do
                it "returns the vcs url" do
                    assert_equal "git://github.com/drivers-iodrivers_base",
                                 package.repo_url
                end

                it "returns an existing autobuild package instance" do
                    autobuild = ws_add_package_to_layout(
                        :cmake,
                        "drivers/iodrivers_base"
                    ).autobuild

                    assert_equal autobuild, package.autobuild
                end
                it "creates a fake package if there is no instance" do
                    assert_equal "drivers/iodrivers_base", package.autobuild.name
                end
            end

            describe "#default_branch" do
                attr_reader :temp_dir

                def untar(file)
                    dir = Dir.mktmpdir
                    data_dir = File.join(File.dirname(__FILE__), "../../", "data")
                    FileUtils.mkdir_p(dir, mode: 0o700)
                    Autobuild.logdir = "#{dir}/log"
                    FileUtils.mkdir_p Autobuild.logdir
                    Autobuild.silent = true
                    file = File.expand_path(file, data_dir)
                    Dir.chdir(dir) do
                        system("tar xf #{file}")
                    end
                    dir
                end

                def remove_tar(dir)
                    FileUtils.rm_rf dir
                end

                describe "#non_master_default_branch" do
                    before do
                        @temp_dir = untar("gitrepo-nomaster.tar.xz")
                        @ws = ws_create
                        @package = PackageRepository.new(
                            "teste_no_master",
                            { type: "git",
                              url: File.join(temp_dir, "gitrepo-nomaster.git") },
                            ws: ws,
                            local_dir: File.join(temp_dir, "gitrepo-nomaster.git")
                        )
                    end
                    it "see current default branch" do
                        assert_equal "temp/branch", package.branch
                    end

                    after do
                        remove_tar(temp_dir)
                    end
                end

                describe "#defined_branch" do
                    before do
                        @temp_dir = untar("gitrepo-nomaster.tar.xz")
                        @ws = ws_create
                        @package = PackageRepository.new(
                            "teste_no_master",
                            { type: "git",
                              url: File.join(temp_dir, "gitrepo-nomaster.git"),
                              branch: "other_branch" },
                            ws: ws,
                            local_dir: File.join(temp_dir, "gitrepo-nomaster.git")
                        )
                    end

                    it "see current default branch" do
                        assert_equal "other_branch", package.branch
                    end

                    after do
                        remove_tar(temp_dir)
                    end
                end
            end
        end
    end
end
