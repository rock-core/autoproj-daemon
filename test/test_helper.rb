$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "autoproj/cli/daemon"
require "autoproj/test"

require "minitest/autorun"
require "minitest/spec"
