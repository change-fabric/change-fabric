#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'inbox_paths'

# Owns roster.json: the human-edited, sole source of truth for a project's
# role set. There is no hardcoded ROLES constant anywhere in this toolkit;
# every role-taking or actor-taking verb loads its vocabulary from here and
# refuses cleanly when the roster is missing or a role is unknown.
#
# Shape written by `init`, hand-editable afterwards:
#   { "roles": ["PLAN","BUILD","QA"],
#     "sessions": {"PLAN":"plan-session","BUILD":"","QA":""},
#     "humans": ["operator"],
#     "chain": "PLAN -> BUILD -> QA" }
#
# A legacy corpus shipped a two-key shape, {"roles": {ROLE: name}, "chain":
# "..."}. When roster["roles"] is a Hash rather than an Array, its keys are
# the roles and the hash itself is the sessions map.
module InboxRoster
  def self.path(root) = File.join(root, 'roster.json')

  # Fail-soft: any read or parse trouble, or a missing file, yields {} so no
  # caller ever crashes on a bad roster.json. Everything downstream treats an
  # empty hash the same as "no roster".
  def self.load(root)
    data = JSON.parse(File.read(path(root)))
    return {} unless data.is_a?(Hash)

    migrate(data)
  rescue StandardError
    {}
  end

  # Legacy Hash-shaped roles: {"roles": {"PLAN" => "plan-session", ...}}.
  # Its keys become the role list, and the hash itself becomes the sessions
  # map, so a legacy roster.json keeps working with no manual migration.
  def self.migrate(data)
    return data unless data['roles'].is_a?(Hash)

    legacy = data['roles']
    data.merge('roles' => legacy.keys.map(&:to_s), 'sessions' => data['sessions'] || legacy)
  end

  def self.roles(root) = Array(load(root)['roles']).map(&:to_s)

  def self.humans(root) = Array(load(root)['humans']).map(&:to_s)

  def self.actors(root) = roles(root) + %w[all] + humans(root)

  # Case-insensitive lookup of an actor input against the actual roster.
  # Roles and "all" are conventionally upper/lowercase already; humans are
  # retained exactly as roster.json spells them (e.g. "operator"), so a
  # human match returns that stored spelling rather than whatever case the
  # caller typed. No match returns the input unchanged, so callers still see
  # the value they passed when reporting a bad_actor error.
  def self.normalize_actor(root, value)
    value = value.to_s
    actors(root).find { |actor| actor.casecmp?(value) } || value
  end

  def self.sessions(root)
    data = load(root)['sessions']
    data.is_a?(Hash) ? data : {}
  end

  def self.session_name(root, role) = sessions(root)[role] || role

  def self.no_roster?(root) = roles(root).empty?

  # Writes roster.json once. Refuses (returns false) if one already exists;
  # `init` turns that into the roster_exists error. Hand-editing afterwards
  # is the only supported change, deliberately with no --force.
  def self.write(root, roles:, humans: [], chain: nil)
    return false if File.exist?(path(root))

    sessions = roles.each_with_object({}) { |role, memo| memo[role] = '' }
    data = { 'roles' => roles, 'sessions' => sessions, 'humans' => humans,
             'chain' => chain || roles.join(' -> ') }
    InboxPaths.write_atomically(path(root), JSON.pretty_generate(data))
    true
  end

  # Binds a role to a cross-session SendMessage recipient name. Only called
  # when the caller has already validated the role against roles(root).
  def self.bind_session(root, role:, name:)
    data = load(root)
    return false if data.empty?

    data['sessions'] ||= {}
    data['sessions'][role] = name
    InboxPaths.write_atomically(path(root), JSON.pretty_generate(data))
    true
  end
end
