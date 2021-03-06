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
        end
    end
end
