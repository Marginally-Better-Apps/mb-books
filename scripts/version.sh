#!/usr/bin/env bash
set -euo pipefail
# Release tags are the version source of truth. The project value is a first-build fallback.
if [[ -z "${APP_VERSION:-}" ]]; then
  tag="$(git tag --list 'v[0-9]*' --sort=-version:refname | head -n 1)"
  APP_VERSION="${tag#v}"
  APP_VERSION="${APP_VERSION:-0.1.0}"
fi
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'APP_VERSION must be a stable semantic version' >&2
  exit 1
fi
# GitHub run numbers increase across CI builds. Gala replaces the build number when signing.
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
if [[ ! "$APP_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo 'APP_BUILD_NUMBER must be a positive integer' >&2
  exit 1
fi
export APP_VERSION APP_BUILD_NUMBER
