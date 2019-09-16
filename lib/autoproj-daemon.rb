require 'autoproj/cli/main_ci'

class Autoproj::CLI::Main
    desc 'daemon', 'subcommands to control a daemon-like behavior'
    subcommand 'daemon', Autoproj::CLI::MainDaemon
end
