# Fleet engine launch

## Launcher contract, #80
Fleet game launches go through shared `launch-game.sh`, reached through `scripts/shared.sh` at `shared-scripts.pin`. An ad-hoc `nohup ... &` bypasses that lifecycle. Script details and fullscreen shutdown hazards: `docs/SCRIPT-CONTRACTS.md` and `docs/legacy-mac-hardware.md`.
