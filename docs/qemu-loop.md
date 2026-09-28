# qemu-tiger3d PPC-in-VM loop

Iterate on the PPC build without real hardware: deploy, smoke, bench-evidence and a frame check, all in one claim on the emulated G4 (Tiger). Claim first; qemumac and other ports share the VM. Sections: Commands, Notes.

## Commands
Run inside `scripts/pick-bench-host.sh --run qemu-tiger3d <label> -- <script>`:
1. `scripts/deploy.sh qemu-tiger3d`
2. `scripts/smoke-dmg.sh qemu-tiger3d`
3. `BENCH_ARTEFACT=$PWD/build/quakespasm-fat-deployed BENCH_ADAPTER=$PWD/scripts/bench-adapter.sh scripts/shared.sh bench-evidence.sh qemu-tiger3d <label>`
4. `scripts/screenshot.sh qemu-tiger3d` (frame check)

## Notes
- Games start through shared `launch-game.sh` (one game per host); see `docs/ticketing.md` for lock exports.
- Bundles are marked VM; class fps floors are met on real hardware, not here.
- A VM-only fault may be the emulator: route it to qemumac before blaming the port.
