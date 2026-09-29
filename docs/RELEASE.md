# Release inputs

Fleet release procedure governs promotion; this page maps the port's inputs.

## Build and package
`docs/TOOLCHAIN.md` covers the six slices; `docs/DEVELOPMENT.md` covers the build path. `scripts/make-dmg.sh` uses a Tiger host and content-verifies the binaries inside the DMG against source. Versioning and package decisions are in `docs/adr/README.md`, ADRs 0004 and 0005.

## Installed checks
Use `scripts/deploy-dmg.sh` and `scripts/smoke-dmg.sh` through their pinned shared-tool shims. Run `scripts/selfhost-download-test.sh` for download acceptance. Detailed script contracts: `docs/SCRIPT-CONTRACTS.md`.
