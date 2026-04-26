#!/usr/bin/env bash

# renovate: datasource=docker depName=ghcr.io/biomejs/biome versioning=docker
export biome_hook_image="${CONTROL_PLANE_TEST_BIOME_HOOK_IMAGE:-ghcr.io/biomejs/biome:2.4.13}"
