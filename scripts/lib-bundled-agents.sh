#!/usr/bin/env bash

CONTROL_PLANE_BUNDLED_AGENT_SPECS=(
  'implementation-agent|implementation-agent.agent.md'
  'kiss-dry-review-agent|kiss-dry-review-agent.agent.md'
  'solid-review-agent|solid-review-agent.agent.md'
  'security-review-agent|security-review-agent.agent.md'
  'architecture-review-agent|architecture-review-agent.agent.md'
  'review-coordinator-agent|review-coordinator-agent.agent.md'
)

control_plane_bundled_agent_specs() {
  printf '%s\n' "${CONTROL_PLANE_BUNDLED_AGENT_SPECS[@]}"
}
