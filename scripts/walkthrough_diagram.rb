# frozen_string_literal: true

# Diagram scenes for cf:walkthrough: a full-frame React Flow diagram built and
# moved on screen under the capture clock. This file is a stub for now; it
# holds the pin for the vendored engine that later phases inline.
#
# xyflow is vendored, not fetched, for the same reason axe-core is (see
# scripts/change_lane_a11y.rb): a diagram scene must render the same frames
# every time, and a library pulled at capture time could change underneath a
# cached scene without a line of this repo changing. The bundle under
# scripts/vendor/xyflow is rebuilt reproducibly by scripts/xyflow_vendor.rb
# inside the pinned Node image, and `--check` confirms a rebuild matches the
# sha256 below. Upgrading means bumping the version in the build inputs and
# here, rebuilding, and committing the new file and sha on purpose; the new
# sha invalidates every cached diagram scene by design.
module WalkthroughDiagram
  XYFLOW_VERSION = '12.12.1'
  XYFLOW_BUNDLE = File.join(__dir__, 'vendor', 'xyflow', "xyflow-#{XYFLOW_VERSION}.min.js")
  XYFLOW_SHA256 = 'c459e26cdb12eea049b16060a2c18938df9c417bc5f357902e7d4a3f9c5c86aa'
end
