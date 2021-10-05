#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rest_client'
require 'json'
require 'octokit'
require 'fileutils'
require 'yaml'

# Export from these organizations
ORGS = %w[teamdigitale italia].freeze

# Project's prefixes we can translate to a user friendly string in the UI.
# See todo_projects_dict in _data/l10n.yml.
PROJECS_PREFIX = %w[spid- 18app anpr- daf- dati- pianotriennale- lg- design- security- cie-].freeze

# List of technologies shown in the UI
TECH_LIST = %w[
  angular react design html arduino bootstrap frontend
  perl python cpp scala php csharp java android ios dotnet
  wordpress metabase ansible docker magento joomla django
].sort.freeze

# Import issues with at least one of these labels
ONLY_WITH_LABEL = ['help wanted', 'Hacktoberfest'].freeze

# Show these labels in the UI, if present.
ISSUE_TYPES = ['bug', 'enhancement', 'new project', 'Hacktoberfest'].freeze

# Ignore these repos using the full_name (ie. 'organization/repo')
BLACKLISTED_REPOS = [].freeze

GH_ACCESS_TOKEN = ENV.fetch('GH_ACCESS_TOKEN', '')

SAVE_TO_REPO = "bfabio/developers.italia.it-data"

def fetch(url, headers = {})
  rest_params = {
    'per_page' => 100,
    'page' => 1,
    'type' => 'public'
  }

  results = []
  loop do
    print "."
    response = JSON.parse(RestClient.get(url, {
      Authorization: "token #{GH_ACCESS_TOKEN}", params: rest_params
    }.merge(headers)))

    if response.is_a? Array
      results += response
    else
      results = response
      break
    end
    break if response.size != rest_params['per_page']

    rest_params['page'] += 1
  end

  results
end

def fetch_teams(org)
  teams = fetch("https://api.github.com/orgs/#{org}/teams")

  teams.map do |team|
    members = fetch("#{team['url']}/members")

    # Only get the fields we use in the frontend, so we don't end up
    # cluttering the history for fields we don't even use.
    team['members'] = members.map { |m| fetch(m['url']).slice('login', 'name', 'avatar_url', 'html_url') }

    team
  end
end

def fetch_issues(repos)
  github_issues = []

  repos.each do |repo|
    open_issues, full_name = repo.values_at('open_issues_count', 'full_name')

    next if open_issues.zero? || BLACKLISTED_REPOS.include?(full_name)

    issues = fetch("https://api.github.com/repos/#{full_name}/issues")
    issues.each do |issue|
      next if issue.key?('pull_request')

      labels = issue['labels'].map { |label| label['name'] }

      # XXX: ugly hack: issues can have just one type, but we treat issues labelled
      # with "Hacktoberfest" as a new type because of the limits of the UI implementation.
      #
      # Let's have "Hacktoberfest" issues take precedence over "bug" whenever a
      # certain issue has both the labels ("Hacktoberfest" being capitalized comes before
      # uncapitalized labels)
      labels.sort!

      # Only get the issues marked with at least one label in ONLY_WITH_LABEL
      next unless labels.any? { |item| ONLY_WITH_LABEL.include? item }

      issue_data = {
        'created_at' => issue['created_at'],
        'url' => issue['html_url'],
        'title' => issue['title'],
        'name' => repo['name'],
        'language' => TECH_LIST & repo['topics'],
        'repository_url' => repo['html_url'],
        'labels' => labels,
        'type' => (labels & ISSUE_TYPES).first || '',
        'subproject' => repo['name']
      }

      # Remove the issue label(s) marking this as help wanted, so they don't
      # get displayed in the UI.
      issue_data['labels'].reject! { |label| ONLY_WITH_LABEL.include? label }

      # Set the main project name.
      # The user facing strings are translated in _data/l10n.yml.
      prefix = PROJECS_PREFIX.find { |p| repo['name'].start_with?(p) }
      issue_data['project'] = if prefix
                                prefix.tr('-', '')
                              elsif repo['name'] =~ /.italia.it|\.gov.it|\.governo\.it/
                                'website'
                              else
                                'other'
                              end
      github_issues.push(issue_data)
    end
  end
  github_issues
end

def git_update_file(client, path, contents)
  resp = client.contents(SAVE_TO_REPO, path: path)
  orig_contents = Base64.decode64(resp.content).force_encoding('UTF-8')

  if orig_contents == contents
    puts "#{path} unchanged"
    return
  else
    puts "Updating #{path}..."
  end

  client.create_contents(SAVE_TO_REPO,
                         path,
                         ":robot: Update #{path}",
                         contents,
                         sha: resp.sha,
                         branch: 'main')
end

abort 'Set GH_ACCESS_TOKEN first.' if GH_ACCESS_TOKEN.empty?

repos = ORGS.map do |org|
  fetch(
    "https://api.github.com/orgs/#{org}/repos", {
      accept: 'application/vnd.github.mercy-preview+json'
    }
  )
end.flatten
puts "Got #{repos.size} GitHub repos"

github_issues = fetch_issues(repos)
puts "Got #{github_issues.size} issues"

github_teams = fetch_teams('italia')
puts "Got #{github_teams.size} teams"

# Fetch org members
client = Octokit::Client.new(access_token: GH_ACCESS_TOKEN)
client.auto_paginate = true

github_members = client.organization_public_members('italia').map { |m| m.to_hash.transform_keys(&:to_s) }
puts "Got #{github_members.size} members"

git_update_file(client, "github_issues.json", github_issues.to_json)

git_update_file(client, "github_teams.yml", github_teams.to_yaml)
git_update_file(client, "github_members.yml", github_members.to_yaml)
git_update_file(client, "github_tech_list.yml", TECH_LIST.to_yaml)
