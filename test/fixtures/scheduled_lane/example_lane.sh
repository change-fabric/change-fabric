#!/bin/sh
# A stand-in lane: writes a passing cf-lane-result/1 file for this run.
set -e
mkdir -p "$(dirname "$CF_LANE_RESULT_FILE")"
printf '{"schema":"cf-lane-result/1","run_id":"%s","status":"pass","cases":[{"name":"switch-view","grade":"pass","step_ms":120,"reason":null}]}\n' \
  "$CF_LANE_RUN_ID" > "$CF_LANE_RESULT_FILE"
