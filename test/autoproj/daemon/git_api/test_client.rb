# frozen_string_literal: true

require "autoproj/daemon/git_api/client"
require "test_helper"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Github API main module
        module GitAPI
            describe Client do
                include Autoproj::Daemon::TestHelpers
                attr_reader :client

                before do
                    autoproj_daemon_create_ws(
                        type: "git",
                        url: "git@github.com:rock-core/buildconf"
                    )
                    @client = Client.new(ws)
                end

                it "retries on connection failure" do
                    runs = 0
                    flexmock(client).should_receive(:check_rate_limit_and_wait)
                    assert_raises GitAPI::ConnectionFailed do
                        client.with_retry(nil, 1) do
                            runs += 1
                            raise GitAPI::ConnectionFailed, "Connection failed"
                        end
                    end
                    assert_equal 2, runs
                end

                it "retries on rate limiting error" do
                    runs = 0
                    flexmock(client).should_receive(:check_rate_limit_and_wait)
                                    .times(5)
                    client.with_retry(nil, 1) do
                        runs += 1
                        raise GitAPI::TooManyRequests.new, "rate limit" if runs < 5
                    end
                    assert_equal 5, runs
                end

                it "returns a human readable time" do
                    assert_equal "2h", client.humanize_time(2 * 60 * 60)
                    assert_equal "17m", client.humanize_time(17 * 60)
                    assert_equal "23s", client.humanize_time(23)
                    assert_equal "2h17m23s",
                                 client.humanize_time(2 * 60 * 60 + 17 * 60 + 23)
                end

                it "watis for the remaining time until next limit reset" do
                    rate_limit = flexmock
                    service = flexmock(Service.new(host: "github.com"))
                    service.should_receive(:rate_limit).and_return(rate_limit)

                    @client = Client.new(ws)
                    rate_limit.should_receive(:remaining).and_return(0)
                    rate_limit.should_receive(:resets_in).and_return(15)
                    flexmock(client).should_receive(:sleep).explicitly.with(16).once
                    client.check_rate_limit_and_wait(service)
                end
            end
        end
    end
end
