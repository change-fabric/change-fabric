#!/usr/bin/env ruby
# frozen_string_literal: true

# The testcases lane's login cache: one stored browser session per persona,
# shared by every case that runs as that persona.
#
# A persona logs in once per run, and each case gets that login's storage state
# (cookies plus localStorage) seeded into its own fresh browser context. Those
# cases therefore share one server-side session, which is the documented cost of
# not logging in forty times.
#
# The cache is the one place a session is refreshed. Each persona has a lock, the
# current state and an integer generation. A case that saw its session expire
# asks for a refresh carrying the generation it was seeded with. Under the lock,
# if the generation has already moved on, another case refreshed first and this
# one reuses that state; otherwise this caller logs in and bumps the generation.
# So any number of cases that see the same logout cause exactly one login.
class PersonaCache
  # A login that did not produce a session. Raised to every caller of that
  # generation, so a broken login fails each case of the persona by name rather
  # than being retried once per case.
  LoginError = Class.new(StandardError)

  Entry = Struct.new(:mutex, :state, :generation, :error)

  attr_reader :logins

  # `login` is called with a persona name and returns its storage state, or
  # raises LoginError. It is the only thing that talks to the container.
  def initialize(&login)
    @login = login
    @entries = Hash.new { |hash, name| hash[name] = Entry.new(Mutex.new, nil, 0, nil) }
    @registry = Mutex.new
    @logins = Hash.new(0)
  end

  # The persona's current state and generation, logging in first if nobody has.
  def fetch(name)
    entry = entry(name)
    entry.mutex.synchronize do
      login!(name, entry) if entry.generation.zero?
      current(entry)
    end
  end

  # A fresh state for a caller whose session expired at `seen_generation`.
  def refresh(name, seen_generation)
    entry = entry(name)
    entry.mutex.synchronize do
      login!(name, entry) if entry.generation <= seen_generation
      current(entry)
    end
  end

  private

  def entry(name) = @registry.synchronize { @entries[name] }

  def login!(name, entry)
    @registry.synchronize { @logins[name] += 1 }
    entry.generation += 1
    entry.state = nil
    entry.error = nil
    entry.state = @login.call(name)
  rescue LoginError => e
    entry.error = e.message
  end

  def current(entry)
    raise LoginError, entry.error if entry.error

    [ entry.state, entry.generation ]
  end
end
