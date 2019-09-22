$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require 'autoproj/daemon'
require 'autoproj/test'

require 'minitest/autorun'
require 'minitest/spec'

require 'octokit'
def mock_github_client
    headers = { date: Time.now.to_s }
    last_response = flexmock(interactive?: false)
    last_response.should_receive(:headers).and_return(headers)

    user = flexmock(interactive?: false)
    user.should_receive(:login)

    client = flexmock(Octokit::Client).new_instances
    client.should_receive(:user).and_return(user)
    client.should_receive(:last_response).and_return(last_response)
end