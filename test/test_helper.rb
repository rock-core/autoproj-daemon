# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'autoproj/daemon'
require 'autoproj/test'
require 'minitest/autorun'
require 'minitest/spec'

require 'rubygems/package'

def create_pull_request(options)
    Autoproj::Daemon::Github::PullRequest.new(
        state: options[:state],
        number: options[:number],
        title: options[:title],
        updated_at: options[:updated_at] || Time.now,
        base: {
            ref: options[:base_branch],
            sha: options[:base_sha],
            user: {
                login: options[:base_owner]
            },
            repo: {
                name: options[:base_name]
            }
        },
        head: {
            ref: options[:head_branch],
            sha: options[:head_sha],
            user: {
                login: options[:head_owner]
            },
            repo: {
                name: options[:head_name]
            }
        }
    )
end

def create_branch(owner, name, options)
    Autoproj::Daemon::Github::Branch.new(
        owner, name,
        name: options[:branch_name],
        commit: {
            sha: options[:sha]
        }
    )
end

def create_pull_request_event(options)
    pr = options[:pull_request] || create_pull_request(base_owner: options[:base_owner],
                                                       base_name: options[:base_name],
                                                       base_branch: options[:base_branch],
                                                       state: options[:state])

    Autoproj::Daemon::Github::PullRequestEvent.new(
        payload: {
            pull_request: pr.instance_variable_get(:@model)
        },
        created_at: options[:created_at]
    )
end

def create_push_event(options)
    Autoproj::Daemon::Github::PushEvent.new(
        repo: {
            name: "#{options[:owner]}/#{options[:name]}"
        },
        payload: {
            head: options[:head_sha],
            ref: "refs/heads/#{options[:branch]}"
        },
        created_at: options[:created_at]
    )
end
