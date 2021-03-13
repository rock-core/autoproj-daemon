# frozen_string_literal: true

require "test_helper"
require "autoproj/daemon/git_api/url"

module Autoproj
    module Daemon
        # :nodoc:
        module GitAPI
            describe URL do
                it "raises if url is invalid" do
                    assert_raises(ArgumentError) { URL.new("www.github.com/foo/bar") }
                end

                it "compares git urls" do
                    assert_equal URL.new("ssh://git@github.com/rock-core/buildconf"),
                                 URL.new("git://GITHUB.com/rock-core///buildconf.git")

                    assert_equal URL.new("git://www.github.com/rock-core/buildconf"),
                                 URL.new("git://GITHUB.com/rock-core///buildconf.git")

                    assert_equal URL.new("git@www.github.com:rock-core/buildconf.git"),
                                 URL.new("git://GITHUB.com/rock-core/buildconf")

                    assert_equal URL.new("git://github.com/rock-core/buildconf"),
                                 URL.new("https://GITHUB.COM/rock-core/buildconf")

                    refute_equal URL.new("git://github.com/rock-core/buildconf"),
                                 URL.new("git://gitlab.com/rock-core/buildconf")
                end

                it "returns a normalized host" do
                    assert_equal "github.com", URL.new("git://GITHUB.COM/foo/bar").host
                    assert_equal "github.com", URL.new("git://www.github.com/f/b").host
                    assert_equal "github.com", URL.new("git@GITHUB.COM:foo/bar").host
                end

                it "returns a normalized path" do
                    assert_equal "foo/bar", URL.new("git://GITHUB.COM/foo/bar.git").path
                    assert_equal "foo/bar", URL.new("git://www.github.com/FOO/bar").path
                    assert_equal "foo/bar", URL.new("git@GITHUB.COM:FOO///BAR").path
                end
            end
        end
    end
end
