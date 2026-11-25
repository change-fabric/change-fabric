# frozen_string_literal: true

require_relative 'local_store'
require_relative 'recorder'
require_relative '../change_policy'

module ApprovalConsole
  # Picks which enrolled console a repo's approvals go to: the one its
  # authoritative change_policy.approval_pins.rp_id names (base or default
  # branch, never the working tree). A repo with no pins, or whose policy
  # cannot be read, gets the default console. Routing only chooses where to
  # ask; every gate still checks the local pins against the authoritative
  # ones, so a wrong route fails closed rather than passing.
  module Route
    module_function

    # The authoritative rpId for the repo at `root`, or nil. `authority` is a
    # resolved ChangePolicy::Authority, nil for none, or :default to fetch it.
    def rp_id(root, authority: :default)
      authority = Recorder.authority_for(root) if authority == :default
      pins = authority.respond_to?(:policy) ? authority.policy&.approval_pins : nil
      rp = pins && pins['rp_id'].to_s
      rp.nil? || rp.empty? ? nil : rp
    rescue ChangePolicy::Unreadable
      nil
    end

    # `base` bound to the repo's console, or `base` itself when it has none.
    def store(root, base: LocalStore.new, authority: :default)
      rp = rp_id(root, authority: authority)
      rp ? base.for_console(rp) : base
    end
  end
end
