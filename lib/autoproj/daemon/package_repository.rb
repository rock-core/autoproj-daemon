# frozen_string_literal: true

require 'autobuild'
require 'autoproj/ops/tools'
require 'autoproj/vcs_definition'

module Autoproj
    module Daemon
        # A Package repository model representation
        class PackageRepository
            # @return [String]
            attr_reader :package

            # @return [String]
            attr_reader :name

            # @return [String]
            attr_reader :owner

            # @return [Hash]
            attr_reader :vcs

            # @return [String]
            attr_reader :local_dir

            def initialize(package, owner, name, vcs, options = {})
                @package = package
                @name = name
                @owner = owner
                @vcs = vcs
                @package_set = options[:package_set]
                @buildconf = options[:buildconf]
                @local_dir = options[:local_dir]
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
            def branch
                vcs[:remote_branch] || vcs[:branch] || 'master'
            end

            # @return [String]
            def head_sha
                pkg = autobuild
                pkg.importdir ||= local_dir # TODO: What if importdir != srcdir?
                pkg.importer.current_remote_commit(pkg, only_local: true)
            end

            # @return [Autoproj::FakePackage]
            def autobuild
                return Autobuild::Package[package] if Autobuild::Package[package]

                vcs_definition = Autoproj::VCSDefinition.from_raw(vcs)
                Ops::Tools.create_autobuild_package(vcs_definition, package, local_dir)
            end
        end
    end
end