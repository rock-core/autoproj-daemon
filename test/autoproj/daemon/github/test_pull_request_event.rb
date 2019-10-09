# frozen_string_literal: true

require 'autoproj/daemon/github/pull_request_event'

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Github main module
        module Github
            describe PullRequestEvent do
                attr_reader :pull_request_event
                attr_reader :model
                before do
                    @model = JSON.parse(
                        File.read(File.expand_path('pull_request_event.json', __dir__))
                    )

                    @pull_request_event = PullRequestEvent.new(@model)
                end

                it 'returns the state' do
                    assert true, pull_request_event.pull_request.open?.class
                end

                it 'returns the PR number' do
                    assert_equal 1, pull_request_event.pull_request.number
                end

                it 'returns the event timestamp' do
                    assert_equal Time.utc(2019, 'sep', 22, 23, 49, 0),
                                 pull_request_event.created_at
                end
            end
        end
    end
end
