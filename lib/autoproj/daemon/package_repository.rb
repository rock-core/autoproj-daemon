# frozen_string_literal: true

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

            def initialize(package, owner, name, vcs, options = {})
                @package = package
                @name = name
                @owner = owner
                @vcs = vcs
                @package_set = options[:package_set]
                @buildconf = options[:buildconf]
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
        end
    end
end
