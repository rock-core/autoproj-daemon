# frozen_string_literal: true

require "autoproj/daemon/git_api/client"
require "test_helper"

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # :nodoc:
        module GitAPI
            # :nodoc:
            module Services
                def self.dummy(**options)
                    Dummy.new(**options)
                end

                # Dummy service
                class Dummy < Service
                    attr_reader :access_token, :some_extra

                    def initialize(some_extra: nil, **options)
                        super(**options)
                        @access_token = options[:access_token]
                        @some_extra = some_extra
                    end

                    def default_endpoint
                        "https://#{host}/api/v4"
                    end

                    def extract_info_from_pull_request_ref(_, _)
                        ["https://dummy.com/foo/bar", 22]
                    end

                    def test_branch_name(pull_request)
                        "dummy/#{pull_request.number}"
                    end
                end
            end

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
                    service = flexmock(
                        Service.new(
                            host: "github.com",
                            api_endpoint: "https://api.github.com",
                            access_token: "key"
                        )
                    )
                    service.should_receive(:rate_limit).and_return(rate_limit)

                    @client = Client.new(ws)
                    rate_limit.should_receive(:remaining).and_return(0)
                    rate_limit.should_receive(:resets_in).and_return(15)
                    flexmock(client).should_receive(:sleep).explicitly.with(16).once
                    client.check_rate_limit_and_wait(service)
                end

                describe "#extract_info_from_pull_request_ref" do
                    attr_reader :pr

                    before do
                        ws.config.daemon_set_service(
                            "dummy.com", "apikey", "https://dummy", "dummy"
                        )
                        @client = Client.new(ws)
                        @pr = autoproj_daemon_create_pull_request(
                            repo_url: "git@dummy.com:foo/bar.git"
                        )
                    end

                    it "extracts pull request info from ref" do
                        assert_equal ["https://dummy.com/foo/bar", 22],
                                     client.extract_info_from_pull_request_ref(
                                         "foo/bar#22", pr
                                     )
                    end
                end

                describe "#initialize" do
                    it "passes options to services instances" do
                        ws.config.daemon_set_service(
                            "dummy.com", "apikey", "https://dummy", "dummy",
                            some_extra: "option"
                        )
                        @client = Client.new(ws)

                        service = client.service("git@dummy.com:foo/bar")
                        assert_equal Services::Dummy, service.class
                        assert_equal "dummy.com", service.host
                        assert_equal "apikey", service.access_token
                        assert_equal "https://dummy", service.api_endpoint
                        assert_equal "option", service.some_extra

                        assert client.supports?("git@dummy.com:foo/bar")
                        assert client.services.key?("dummy.com")
                    end

                    it "does not support services without access tokens" do
                        ws.config.daemon_set_service(
                            "dummy.com", nil, "https://dummy", "dummy"
                        )
                        @client = Client.new(ws)

                        e = assert_raises(ArgumentError) do
                            client.service("git@dummy.com:foo/bar")
                        end

                        assert_match(/Unsupported/, e.message)
                        refute client.supports?("git@dummy.com:foo/bar")
                        refute client.services.key?("dummy.com")
                    end

                    it "does not support services without api endpoints" do
                        ws.config.daemon_set_service(
                            "dummy.com", "apikey", nil, "dummy"
                        )
                        flexmock(Services::Dummy).new_instances
                                                 .should_receive(:default_endpoint)
                                                 .and_return(nil)

                        @client = Client.new(ws)
                        e = assert_raises(ArgumentError) do
                            client.service("git@dummy.com:foo/bar")
                        end

                        assert_match(/Unsupported/, e.message)
                        refute client.supports?("git@dummy.com:foo/bar")
                        refute client.services.key?("dummy.com")
                    end

                    it "uses default endpoint if unset" do
                        ws.config.daemon_set_service(
                            "dummy.com", "apikey", nil, "dummy"
                        )
                        @client = Client.new(ws)
                        service = client.service("git@dummy.com:foo/bar")
                        assert_equal "https://dummy.com/api/v4", service.api_endpoint
                    end

                    it "uses test branch name from backend" do
                        ws.config.daemon_set_service(
                            "dummy.com", "apikey", nil, "dummy"
                        )
                        @client = Client.new(ws)
                        pr = autoproj_daemon_create_pull_request(
                            number: 1,
                            repo_url: "git@dummy.com:foo/bar.git"
                        )
                        assert_equal "dummy/1", client.test_branch_name(pr)
                    end

                    it "does not allow defining services with unknown backends" do
                        ws.config.daemon_set_service(
                            "dummy.com", "apikey", "https://dummy", "foobar"
                        )
                        e = assert_raises(Autoproj::ConfigError) do
                            @client = Client.new(ws)
                        end
                        assert_match(/not supported/, e.message)
                    end

                    it "does not allow defining services without a backend" do
                        ws.config.daemon_set_service(
                            "dummy.com", "apikey", "https://dummy", nil
                        )
                        e = assert_raises(Autoproj::ConfigError) do
                            @client = Client.new(ws)
                        end
                        assert_match(/Service parameter missing/, e.message)
                    end

                    describe "merging of service configurations" do
                        before do
                            @services = Client::SERVICES
                            Client.const_set(
                                :SERVICES,
                                Client::SERVICES.merge(
                                    {
                                        "dummy.com" => {
                                            "api_endpoint" => "https://dummy.com",
                                            "service" => "dummy",
                                            "access_token" => nil
                                        }
                                    }
                                )
                            )
                        end

                        after do
                            Client.const_set(:SERVICES, @services)
                        end

                        it "merges service configurations" do
                            ws.config.daemon_set_service("dummy.com", "apikey")
                            ws.config.daemon_set_service(
                                "foo.com", "apikey", "https://dummy", "dummy"
                            )
                            @client = Client.new(ws)
                            service = client.service("git@dummy.com:foo/bar")
                            assert_equal Services::Dummy, service.class
                            assert_equal "dummy.com", service.host
                            assert_equal "apikey", service.access_token
                            assert_equal "https://dummy.com", service.api_endpoint

                            service = client.service("git@foo.com:foo/bar")
                            assert_equal Services::Dummy, service.class
                            assert_equal "foo.com", service.host
                            assert_equal "apikey", service.access_token
                            assert_equal "https://dummy", service.api_endpoint
                        end
                    end
                end
            end
        end
    end
end
