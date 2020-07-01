# frozen_string_literal: true

require "autoproj/cli/daemon"
require "autoproj/cli/main_daemon"
require "autoproj/daemon/github_watcher"
require "autoproj/daemon/version"
require "autoproj/daemon/pull_request_cache"
require "autoproj/daemon/buildconf_manager"
require "autoproj/extensions/configuration"

Autoproj::Configuration.class_eval do
    prepend Autoproj::Extensions::Configuration
end
