#!/usr/bin/env bash

CONTROL_PLANE_BUNDLED_AGENT_SPECS=(
  'implementation-agent|implementation-agent.agent.md'
  'change-review-agent|change-review-agent.agent.md'
  'pre-implementation-design-agent|pre-implementation-design-agent.agent.md'
)

control_plane_bundled_agent_specs() {
  printf '%s\n' "${CONTROL_PLANE_BUNDLED_AGENT_SPECS[@]}"
}
