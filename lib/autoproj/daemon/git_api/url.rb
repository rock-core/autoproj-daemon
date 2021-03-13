# frozen_string_literal: true

require "uri"
require "pathname"

module Autoproj
    module Daemon
        module GitAPI
            # Git URL normalization
            class URL
                # @return [String]
                attr_reader :raw

                GIT_RX = /([A-Za-z0-9\-_.]+)@([A-Za-z0-9\-_.]+):(.*)/.freeze

                def initialize(url)
                    @raw = url

                    return if url =~ GIT_RX
                    return if URI.parse(url).scheme

                    raise ArgumentError, "Invalid URL (#{url})"
                end

                def initialize_copy(_)
                    super
                    @raw = @raw.dup
                end

                # @return [URI]
                def uri
                    uri = if (m = raw.match(GIT_RX))
                              _, user, host, path = m.to_a
                              URI.parse("ssh://#{user}@#{host}/#{path}")
                          else
                              URI.parse(raw)
                          end

                    uri = uri.normalize
                    uri.path = Pathname.new(uri.path).cleanpath.to_s.downcase
                    uri
                end

                # @return [String]
                def host
                    uri.host.sub(/^www./, "")
                end

                # @return [String]
                def path
                    uri.path.sub(/.git$/, "")[1..-1]
                end

                # @param [String] url
                # @return [Boolean]
                def same?(url)
                    other = self.class.new(url)
                    host == other.host && path == other.path
                end

                # @param [Autoproj::Daemon::GitAPI::URL] other
                # @return [Boolean]
                def eql?(other)
                    same?(other.uri.to_s)
                end

                # @param [Autoproj::Daemon::GitAPI::URL] other
                # @return [Boolean]
                def ==(other)
                    eql?(other)
                end
            end
        end
    end
end
