# frozen_string_literal: true

require "backports/2.5.0/hash/transform_keys"

require "autoproj/cli/daemon"
require "autoproj/cli/main_daemon"
require "autoproj/daemon/version"
require "autoproj/daemon/pull_request_cache"
require "autoproj/daemon/git_poller"
require "autoproj/extensions/configuration"

Autoproj::Configuration.class_eval do
    prepend Autoproj::Extensions::Configuration
end
