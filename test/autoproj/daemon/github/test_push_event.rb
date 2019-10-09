# frozen_string_literal: true

require 'autoproj/daemon/github/push_event'

# Autoproj's main module
module Autoproj
    # Daemon main module
    module Daemon
        # Github main module
        module Github
            describe PushEvent do # rubocop: disable Metrics/BlockLength
                attr_reader :push_event
                attr_reader :model
                before do
                    @model = JSON.parse(
                        File.read(File.expand_path('push_event.json', __dir__))
                    )

                    @push_event = PushEvent.new(@model)
                end

                it 'returns the author' do
                    assert 'g-arjones', push_event.author
                end

                it 'returns the owner' do
                    assert_equal 'g-arjones', push_event.owner
                end

                it 'returns the name' do
                    assert_equal 'demo_pkg', push_event.name
                end

                it 'returns the branch' do
                    assert_equal 'test_daemon', push_event.branch
                end

                it 'returns the head commit' do
                    assert_equal '3c5609c79355715a84a712fe115a52dadfb89e2a',
                                 push_event.head_sha
                end

                it 'returns the event timestamp' do
                    assert_equal Time.utc(2019, 'sep', 22, 23, 53, 45),
                                 push_event.created_at
                end
            end
        end
    end
end
