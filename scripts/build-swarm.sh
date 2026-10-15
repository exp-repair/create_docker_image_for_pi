#!/usr/bin/env bash
# Build the staging Swarm computer image. The binary comes from the staging
# release feed. DeepSeek is baked from config/pi.env. The image tag is what
# the host's COFORGE_COMPUTER_IMAGE expects.
set -euo pipefail
cd "$(dirname "$0")/.."

export COFORGE_RELEASE_FEED_URL="${COFORGE_RELEASE_FEED_URL:-https://releases-staging.coforge.cn}"
export TAG="${TAG:-coforge-computer:staging}"
exec ./scripts/build.sh
