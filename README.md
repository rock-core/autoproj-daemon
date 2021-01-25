# Autoproj::Daemon


## Installation

Run

~~~
autoproj plugin install autoproj-daemon
~~~

From within an autoproj workspace

The daemon will get its configuration from the workspace's configuration file.
It requires the following keys:

~~~
daemon_project: PROJECT_NAME
daemon_api_key: GITHUB_API_KEY
daemon_polling_period: POLLING_PERIOD_IN_SECONDS
daemon_buildbot_host: BUILDBOT_HOST
daemon_buildbot_port: 8666
~~~

## Usage

## Development

Install the plugin with a `--path` option to use your working checkout

~~~
autoproj plugin install autoproj-daemon --path /path/to/checkout
~~~

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/rock-core/autoproj-daemon. This project is intended to be a
safe, welcoming space for collaboration, and contributors are expected to
adhere to the [Contributor Covenant](http://contributor-covenant.org) code of
conduct.

## License

The gem is available as open source under the terms of the [BSD 3-Clause
License](https://opensource.org/licenses/BSD-3-Clause).

## Code of Conduct

Everyone interacting in the Autoproj::Daemon project’s codebases, issue trackers,
chat rooms and mailing lists is expected to follow the [code of
conduct](https://github.com/rock-core/autoproj-daemon/blob/master/CODE_OF_CONDUCT.md).
