# frozen_string_literal: true

require "autobuild"
require "autoproj/ops/tools"
require "autoproj/vcs_definition"

module Autoproj
    module Daemon
        # A Package repository model representation
        class PackageRepository
            # @return [String]
            attr_reader :package

            # @return [Hash]
            attr_reader :vcs

            # @return [String]
            attr_reader :local_dir

            # @return [Autoproj::Workspace]
            attr_reader :ws

            def initialize(package, vcs, options = {})
                @package = package
                @vcs = vcs
                @package_set = options[:package_set]
                @buildconf = options[:buildconf]
                @local_dir = options[:local_dir]
                @ws = options[:ws]
            end

            # @return [Boolean]
            def package_set?
                @package_set
            end

            # @return [Boolean]
            def buildconf?
                @buildconf
            end

            # @return [String]
            def repo_url
                vcs[:url]
            end

            # @return [String]
            def branch
                vcs[:remote_branch] || vcs[:branch] || "master"
            end

            # @return [String]
            def head_sha
                out, err, status = Open3.capture3(
                    "git", "-C", local_dir, "rev-parse", "HEAD"
                )
                raise err unless status.success?

                out.strip
            end

            # @return [Autobuild::Package]
            def autobuild
                pkg = ws.manifest.find_autobuild_package(package)
                return pkg if pkg

                vcs_definition = Autoproj::VCSDefinition.from_raw(vcs)
                Ops::Tools.create_autobuild_package(vcs_definition, package, local_dir)
            end
        end
    end
end
