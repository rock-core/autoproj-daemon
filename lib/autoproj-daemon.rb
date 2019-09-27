# rubocop:disable Naming/FileName
# frozen_string_literal: true

require 'autoproj/daemon'

module Autoproj
    module CLI
        # Autoproj's main CLI class
        class Main
            desc 'daemon', 'subcommands to control a daemon-like behavior'
            subcommand 'daemon', Autoproj::CLI::MainDaemon
        end
    end
end
# rubocop: enable Naming/FileName
