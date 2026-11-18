# frozen_string_literal: true

# Preloaded (ruby -r) into a fresh roast.rb process by the re-voice resume
# test: swaps the FFmpeg container for the recorded fake, with tags from
# CF_TEST_DOCKER_TAGS, so the subprocess needs no Docker.
require "json"
require_relative "../scripts/roast_audio_gate"
require_relative "roast_audio_helpers"

RoastAudioGate.send(:remove_const, :DEFAULT_DOCKER)
RoastAudioGate.const_set(:DEFAULT_DOCKER, RoastAudioHelpers::FakeDocker.new(tags: JSON.parse(ENV.fetch("CF_TEST_DOCKER_TAGS", "{}"))))
