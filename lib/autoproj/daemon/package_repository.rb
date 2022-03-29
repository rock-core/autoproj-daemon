# frozen_string_literal: true

require "autobuild"
require "autoproj/ops/tools"
require "autoproj/vcs_definition"
require "autobuild/import/git"

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
            def overrides_key
                Autoproj::VCSDefinition.from_raw(vcs).overrides_key
            end

            # @return [String]
            def branch
                explicit_branch = vcs[:remote_branch] || vcs[:branch]
                return explicit_branch if explicit_branch

                autobuild.importer.resolve_remote_head(
                    autobuild
                )
            rescue Autobuild::SubcommandFailed
                Autobuild.warn "Could not retrieve branch for "\
                               "#{package}, seting to master"
                "master"
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
