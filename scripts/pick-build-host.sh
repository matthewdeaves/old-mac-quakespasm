#!/bin/sh
# pick-build-host.sh - path-stable shim onto build-host#105's pinned scripts
# (docs/adr/0007 in old-mac-build-host, this repo's shared-scripts.pin).
#
# Kept at THIS path, not deleted, because old-mac-build-host's generated
# Jenkins jobs (jenkins/generated/job-*-quakespasm*.xml, job-fleet-status.xml)
# invoke it as "$REPO/scripts/pick-build-host.sh" by fixed path (build-host#118
# / halflife#49).
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SELF_DIR/shared.sh" pick-build-host.sh "$@"
