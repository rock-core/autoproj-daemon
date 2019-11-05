# frozen_string_literal: true

require 'autoproj/daemon/overrides_retriever'
require 'octokit'

module Autoproj
    # Main daemon module
    module Daemon
        describe OverridesRetriever do # rubocop: disable Metrics/BlockLength
            # @return [Autoproj::Daemon::OverridesRetriever]
            attr_reader :retriever

            # @return [FlexMock]
            attr_reader :client

            before do
                @client = flexmock
                @retriever = OverridesRetriever.new(client)
                @pull_requests = {}
                client.should_receive(:pull_requests)
                      .with(any, any)
                      .and_return do |owner, name|
                          @pull_requests["#{owner}/#{name}"] || []
                      end
            end

            def add_pull_request(owner, name, number, body, state: 'open')
                pr = create_pull_request(
                    base_owner: owner,
                    base_name: name,
                    body: body,
                    number: number,
                    state: state
                )
                @pull_requests["#{owner}/#{name}"] ||= []
                @pull_requests["#{owner}/#{name}"] << pr
                pr
            end

            describe 'PULL_REQUEST_URL_RX' do
                it 'parses owner, name and number from PR url' do
                    owner, name, number = OverridesRetriever::PULL_REQUEST_URL_RX.match(
                        'https://github.com////g-arjones._1//demo.pkg_1//pull//122'
                    )[1..-1]

                    assert_equal 'g-arjones._1', owner
                    assert_equal 'demo.pkg_1', name
                    assert_equal '122', number
                end
            end

            describe 'OWNER_NAME_AND_NUMBER_RX' do
                it 'parses owner, name and number from PR path' do
                    owner, name, number =
                        OverridesRetriever::OWNER_NAME_AND_NUMBER_RX.match(
                            'g-arjones._1/demo.pkg_1#122'
                        )[1..-1]

                    assert_equal 'g-arjones._1', owner
                    assert_equal 'demo.pkg_1', name
                    assert_equal '122', number
                end
            end
            describe 'NUMBER_RX' do
                it 'parses the PR number from relative PR path' do
                    number =
                        OverridesRetriever::NUMBER_RX.match(
                            '#122'
                        )[1]

                    assert_equal '122', number
                end
            end
            describe '#parse_task_list' do # rubocop: disable Metrics/BlockLength
                it 'parses the list of pending tasks' do
                    body = <<~EOFBODY
                        Depends on:

                        - [ ] one
                        - [ ] two
                        - [x] three
                        - [ ] four
                    EOFBODY

                    tasks = []
                    tasks << 'one'
                    tasks << 'two'
                    tasks << 'four'

                    assert_equal tasks, retriever.parse_task_list(body)
                end
                it 'only parses the first list' do
                    body = <<~EOFBODY
                        Depends on:
                        - [ ] one._1

                        List of something else, not dependencies:
                        - [ ] two
                    EOFBODY

                    tasks = []
                    tasks << 'one._1'
                    assert_equal tasks, retriever.parse_task_list(body)
                end
                it 'allows multilevel task lists' do
                    body = <<~EOFBODY
                        Depends on:
                        - 1. Feature 1:
                          - [ ] one
                          - [ ] two

                        - [ ] Feature 2:
                          - [x] three
                          - [ ] four
                    EOFBODY

                    tasks = []
                    tasks << 'one'
                    tasks << 'two'
                    tasks << 'Feature'
                    tasks << 'four'
                    assert_equal tasks, retriever.parse_task_list(body)
                end
            end
            describe '#task_to_pull_request' do # rubocop: disable Metrics/BlockLength
                it 'returns a pull request when given a url' do
                    pr = add_pull_request('g-arjones._1', 'demo.pkg_1', 22, '')
                    assert_equal pr, retriever.task_to_pull_request(
                        'https://github.com/g-arjones._1/demo.pkg_1/pull/22', pr
                    )
                end
                it 'returns a pull request when given a full path' do
                    pr = add_pull_request('g-arjones._1', 'demo.pkg_1', 22, '')
                    assert_equal pr, retriever.task_to_pull_request(
                        'g-arjones._1/demo.pkg_1#22', pr
                    )
                end
                it 'returns a pull request when given a relative path' do
                    pr = add_pull_request('g-arjones._1', 'demo.pkg_1', 22, '')
                    assert_equal pr, retriever.task_to_pull_request(
                        '#22', pr
                    )
                end
                it 'returns nil when the task item does not look like a PR reference' do
                    assert_nil retriever.task_to_pull_request(
                        'Feature', nil
                    )
                end
                it 'returns nil if the PR cannot be found' do
                    assert_nil retriever.task_to_pull_request(
                        'https://github.com/g-arjones/demo_pkg/pull/22', nil
                    )
                end
                it 'returns nil if the github resource does not exist' do
                    @client = flexmock
                    @retriever = OverridesRetriever.new(client)

                    client.should_receive(:pull_requests)
                          .with(any, any).and_raise(Octokit::NotFound)

                    assert_nil retriever.task_to_pull_request(
                        'https://github.com/g-arjones/demo_pkg/pull/22', nil
                    )
                end
            end
            # rubocop: disable Metrics/BlockLength
            describe '#retrieve_dependencies' do
                it 'recursively fetches pull request dependencies' do
                    body_driver_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] tidewise/drivers-orogen-gps_ublox#22
                    EOFBODY
                    pr_drivers_gps_ublox = add_pull_request(
                        'tidewise', 'drivers-gps_ublox',
                        11, body_driver_gps_ublox
                    )

                    body_driver_orogen_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] rock-core/drivers-orogen-iodrivers_base#33
                        - [ ] tidewise/tidewise.common-package_set#44
                    EOFBODY
                    pr_driver_orogen_gps_ublox = add_pull_request(
                        'tidewise', 'drivers-orogen-gps_ublox',
                        22, body_driver_orogen_gps_ublox
                    )

                    pr_driver_orogen_iodrivers_base = add_pull_request(
                        'rock-core', 'drivers-orogen-iodrivers_base',
                        33, nil
                    )
                    pr_package_set = add_pull_request(
                        'tidewise', 'tidewise.common-package_set',
                        44, nil
                    )

                    depends = retriever.retrieve_dependencies(pr_drivers_gps_ublox)
                    assert_equal [pr_driver_orogen_gps_ublox,
                                  pr_driver_orogen_iodrivers_base,
                                  pr_package_set], depends
                end
                it 'breaks cyclic dependencies' do
                    body_driver_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] tidewise/drivers-orogen-gps_ublox#22
                    EOFBODY
                    pr_drivers_gps_ublox = add_pull_request(
                        'tidewise', 'drivers-gps_ublox',
                        11, body_driver_gps_ublox
                    )

                    body_driver_orogen_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] tidewise/drivers-gps_ublox#11
                    EOFBODY
                    pr_driver_orogen_gps_ublox = add_pull_request(
                        'tidewise', 'drivers-orogen-gps_ublox',
                        22, body_driver_orogen_gps_ublox
                    )

                    depends = retriever.retrieve_dependencies(pr_drivers_gps_ublox)
                    assert_equal [pr_driver_orogen_gps_ublox], depends
                end
                it 'does not add same PR twice' do
                    body_driver_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] tidewise/drivers-orogen-gps_ublox#22
                        - [ ] rock-core/base-cmake#44
                    EOFBODY
                    pr_drivers_gps_ublox = add_pull_request(
                        'tidewise', 'drivers-gps_ublox',
                        11, body_driver_gps_ublox
                    )

                    body_driver_orogen_gps_ublox = <<~EOFBODY
                        Depends on:
                        - [ ] rock-core/base-cmake#44
                    EOFBODY
                    pr_driver_orogen_gps_ublox = add_pull_request(
                        'tidewise', 'drivers-orogen-gps_ublox',
                        22, body_driver_orogen_gps_ublox
                    )

                    pr_base_cmake = add_pull_request(
                        'rock-core', 'base-cmake',
                        44, nil
                    )

                    depends = retriever.retrieve_dependencies(pr_drivers_gps_ublox)
                    assert_equal [pr_driver_orogen_gps_ublox,
                                  pr_base_cmake], depends
                end
            end
            # rubocop: enable Metrics/BlockLength
        end
    end
end
