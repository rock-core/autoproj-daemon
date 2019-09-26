# frozen_string_literal: true

require 'autoproj/cli/daemon'
require 'autoproj/cli/main_daemon'
require 'autoproj/daemon/version'
require 'autoproj/extensions/configuration'

Autoproj::Configuration.class_eval do
    prepend Autoproj::Extensions::Configuration
end
