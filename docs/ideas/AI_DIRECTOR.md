# AI Director — LLM-driven dynamic encounters

> **Status: FUTURE IDEA. No code exists.** This is a design capture from a
> brainstorm, grounded against the real engine source (file:line references
> are verified against this tree). It is *not* on any roadmap and has not been
> prototyped. Read it as "here's the shape of it and the one trap that will
> bite us" — not as a committed plan.

## Concept in one line

Hook an Opus-class model in as a **Dungeon Master**: it watches the player's
progress and the live combat state, then spawns and directs monsters, places
items, sets mood, and narrates — so a level plays differently every time
instead of running the same scripted encounters.

## Why an LLM fits *this* job

A reasoning model is bad at twitch control and great at the thing a DM
actually does: reading the room and pacing tension (dread → spike → release),
composing encounters that answer how you're playing, and remembering you
across a session. None of that is on the frame-critical path, which is exactly
why it's viable on hardware as old as a G3.

The golden rule that keeps it safe and shippable:

> **The LLM never touches a monster frame-to-frame.** Native QuakeC AI still
> does all navigation, line-of-sight, and shooting. The director runs on a
> slow tick (~3–5 s, async) and emits *intent*. A C-side applier validates
> that intent and executes it on a server frame boundary. **The DM proposes;
> the engine disposes.**

## Architecture

Three boxes. The vintage Mac stays dumb on purpose — it can't even speak
modern TLS, so it never talks to Anthropic directly.

```
┌──────────────────┐   compact game-state    ┌──────────────────┐   HTTPS / TLS 1.3  ┌────────────┐
│  Quake machine   │  (plaintext HTTP/1.0)    │  Sidecar box      │ ─────────────────► │  Anthropic │
│  (G3/G4/Lion)    │ ───────────────────────► │  (fast — e.g. M5) │ ◄───────────────── │   API      │
│                  │ ◄─────────────────────── │                   │                    └────────────┘
│  • emit state    │  director actions (JSON) │  • holds API key  │
│  • apply spawns  │  + TTS audio stream      │  • TLS to API     │
│  • play audio    │                          │  • TTS synthesis  │
│                  │                          │  • per-map room   │
│                  │                          │    graph (cached) │
└──────────────────┘                          └──────────────────┘
```

**Why the sidecar is mandatory, not just nice:** a G3 on Panther (and even
Lion-era curl) can't negotiate TLS 1.2/1.3 with `api.anthropic.com`, and the
engine has no HTTP stack. The sidecar holds the secret (off six vintage
machines), does the slow crypto, runs TTS, and owns any heavy per-map
precompute. The Quake box hits a dead-simple plaintext LAN endpoint that a
hand-rolled `socket()` can satisfy.

**What lives where:**

| Quake machine | Sidecar box |
|---|---|
| Emit compact state each tick | TLS to Anthropic, holds API key |
| Validate + apply director actions on server frame | TTS synthesis (text → PCM stream) |
| Play TTS via a streaming channel | Per-map room/nav graph (computed once, cached) |
| Hard toggle (`ai_director 0`, `-noai`) | Prompt assembly + response parsing |

## Engine mechanics — verified against this tree

### Spawning a creature mid-game is ~5 lines

The map loader's spawn dispatch (`Quake/pr_edict.c:1062–1075`) is the whole
trick, and nothing about it is load-time-specific:

```c
func = ED_FindFunction (classname);             // "monster_ogre" → its spawn fn
pr_global_struct->self = EDICT_TO_PROG(ent);
PR_ExecuteProgram (func - pr_functions);        // runs the real QuakeC spawn
```

A runtime director replicates that: `ED_Alloc()` (`pr_edict.c:111`) → set
`classname` + `origin` → `ED_FindFunction` → `PR_ExecuteProgram`. The result
is a fully real monster — native AI, pain, death, item drops, all of it.
Because Quake is always client/server (single-player runs a local server over
loopback), **the network layer propagates the new entity to the client
automatically.** You spawn server-side; it just appears. No netcode or render
work required.

### "Say where they appear" — any coordinate, and you can validate it

- `PF_setorigin` (`Quake/pr_cmds.c:181`) places the entity and relinks it.
- `SV_TestEntityPosition` (`Quake/world.c:579`) reports whether a spot is
  solid/occupied — **reject a point inside a wall or that would telefrag,
  before committing.**
- `PF_droptofloor` (`Quake/pr_cmds.c:1221`) snaps an entity to the ground and
  returns false if there's no floor — ideal for "drop an item near here,
  settle it onto the surface."

Items are identical: `item_health`, `item_shells`,
`item_artifact_super_damage`, etc. are just entities through the same path.

### ⚠️ The one trap that dominates the design: the precache lock

This is the **MISTAKES.md-grade gotcha** — it smells like "load-time only,
zero risk" and it will instead crash you mid-fight if ignored. When the
feature is actually built and this bites, log it in `MISTAKES.md`.

Monster/item spawn functions call `precache_model`/`precache_sound` for their
`.mdl` and sounds, and those builtins **hard-fail outside load**
(`Quake/pr_cmds.c:1099–1103`):

```c
if (sv.state != ss_loading)
    PR_RunError ("PF_Precache_*: Precache can only be done in spawn functions");
```

So spawning a Shambler into a map that never contained one runs its spawn
function while the server is *active*, hits `precache_model`, and
`PR_RunError`s → dropped game. **You can only freely spawn types whose assets
were precached at load** (i.e. types the map already contains).

**The fix is a hard design requirement:** during the load screen (while
`sv.state == ss_loading`), force-precache the director's *entire roster* —
every monster and item it might ever summon, not just what the mapper placed.
Slots are bounded (`MAX_MODELS`/`MAX_SOUNDS`), but the full base-Quake roster
(~25 models, ~80 sounds) sits comfortably under the cap. See the precache
manifest under "Map-data tooling" below.

### TTS audio — the precache lock bites here too

Runtime-synthesised TTS doesn't exist at load, so it can't use the normal
precache-indexed `S_StartSound` path (`PF_sound` at `Quake/pr_cmds.c:653` →
`SV_StartSound`). The clean route is a **raw streaming channel** — the same
mechanism `Quake/bgmusic.c` uses to stream Ogg/codec audio into the mixer,
which bypasses the precache table. Flow: sidecar synthesises TTS → ships
PCM/WAV → engine plays it on a streaming channel.

Fallback if streaming is fiddly on a G3: a fixed library of pre-rendered
phrases precached at load — less flexible, trivial to implement.

### Threading constraint

`PR_ExecuteProgram` and `ED_Alloc` touch global VM state and the edict array —
**not** safe from the network worker thread. The worker only *receives and
validates* the action list; spawns are applied on the server thread at a frame
boundary (in the `SV_Physics` tick). Same "worker proposes, main thread
disposes" split — but now it has teeth: the spawn itself must be on the main
thread.

## The DM's senses (state sent each tick)

Keep the payload tiny — these machines have little RAM and the LAN hop should
be cheap.

- **Vitals:** health, armor, current weapon, ammo-per-weapon, recent damage rate.
- **Tempo:** kills since last tick, time since last shot, accuracy, and
  *direction of travel* — advancing, backtracking, or camping a chokepoint.
- **Space:** current room, rooms cleared, heading, where secrets/exits are.
- **History:** deaths/retries on this section + a running summary of how the
  player has handled the whole episode so far.

## The DM's levers

- **Composition, not volume.** Pick *which* monsters and *where* — a sniper
  Ogre on a ledge plus Grunts to flush you out, not just "more".
- **Direction & orders.** Set existing monsters' `goalentity`/`enemy` to
  choreograph: regroup at a door, ambush at a chokepoint, retreat to bait.
- **Pacing as a curve.** Dread → spike → release. Hold reinforcements until
  the player *commits* to a room rather than dumping them at once.
- **Item economy as a balancing hand.** Bread-crumb ammo toward a hard fight
  when starved; withhold the quad when dominating.
- **Environment & mood.** Seal a room into an arena; drop fog and kill the
  lights before an ambush (reuses the existing `gl_fog` cvar layer — see
  `docs/KNOBS.md`).
- **Voice.** Centerprint / TTS narration in a persona, reacting to what the
  player just did.

## What turns a spawner into a *Dungeon Master*

This is the replayability hook — what makes runs feel different:

- **Persona, seeded per run.** Cruel, theatrical, fair-but-brutal. Persists
  for the whole session.
- **Memory across the episode.** Carry a running summary so later maps react
  to how earlier ones were cleared.
- **Grudges & adaptation.** Always rocket-jump to the same ledge? Next time a
  Vore is waiting on it. Abuse one weapon? It spawns the monsters that punish
  that range.
- **Difficulty as story, not a slider.** Tune live and *narrate* the tuning —
  ease up after a death but mock you; escalate when you dominate and respect
  you.

## Map-data tooling — two distinct tools

These get conflated. Only the first is required to not crash.

1. **Precache manifest (mandatory, trivial, not per-map).** The fixed roster
   of monster/item assets to force-precache at load so runtime spawns are
   legal. Same list for every map. This is the fix for the precache lock above.

2. **Room/navigation graph (optional, per-map, for *good* placement).**
   Analyse the BSP into named rooms, adjacency, PVS clusters, and legal spawn
   points, so "behind the player in the room they just cleared" resolves to a
   real coordinate.

**Both are derivable from the compiled BSP + runtime state — no source `.map`
files needed.** The BSP already carries the leaf/PVS structure; the entity
lump already lists every teleport destination and monster start spot the
mapper used. A v1 needs *no* offline tool at all: legal spawn points =
existing entity origins + points sampled around the player, each validated
live by `SV_TestEntityPosition`. The offline room graph is the quality
upgrade, and it's a natural job for the sidecar to compute once per map and
cache.

## Action schema + validating applier

The contract is a fixed verb vocabulary in, validated JSON out. The applier
maps verbs to edict operations and **validates every action against caps** —
the model proposes, the engine disposes.

```
spawn(type, where, count, [order])   where = symbolic: behind_player |
                                             cleared_room | ledge | chokepoint
                                             | room_id, resolved to a coordinate
order(group, action)                 flank | ambush | retreat | guard(area) | rush
wave(trigger, beats, escalate)       scripted reinforcement, fires on a condition
item(type, where)                    the economy lever
mood(fog, lights, music)             reuses existing cvars
say(text, style)                     narration / taunt (→ TTS)
boss(base_type, hp_mult, name)       setpiece
```

### The budget cap marries this to the perf project

The applier enforces a hard spawn budget so the model can't drop 200 Shamblers
and tank a G3 to 4 fps. Make that budget a function of **measured framerate
headroom**: small on Sawtooth, large on the iMac 2019. The DM *literally
cannot exceed the machine's playability floor* — the same per-machine gating
pattern the project already uses, applied to encounter density.

## Toggleability + bench discipline

Per project rules (hard requirement): everything off behind `ai_director 0`
cvar and a `-noai` cmdline flag, so it never touches a `timedemo` bench. The
sidecar endpoint is configurable (`ai_host`/`ai_port` cvars). Add the knobs to
`docs/KNOBS.md` when built. Inventory of the new cvars belongs there, not here.

## Suggested build order

1. **Plumbing first.** Sidecar proxy + engine-side async worker thread +
   `ai_director`/`-noai` gate. Prove a text round-trip with no dropped frames
   on a G4. (The simplest payload — the "Oracle" console command — is the
   hello-world here.)
2. **Precache manifest.** Force-precache the roster at load. Without this,
   step 3 crashes.
3. **Spawn + placement applier.** `ED_Alloc`/`PR_ExecuteProgram` path +
   `SV_TestEntityPosition`/`droptofloor` validation, applied on the server
   frame. v1 placement from runtime sampling (no offline tool).
4. **Action schema + budget cap** tied to per-machine framerate headroom.
5. **TTS streaming channel** (bgmusic-style).
6. **Room-graph tool** on the sidecar for quality placement.
7. **DM personality + episode memory** — prompt design on top of the pipe.

## Open questions / risks

- **Spatial grounding quality** without the room graph — how good is
  runtime-sampling-only placement in practice?
- **Latency feel** — does a 3–5 s director tick read as "alive" or "laggy"?
  Probably fine since native AI fills the gaps, but unproven.
- **Precache slot pressure** on asset-heavy maps already near `MAX_MODELS`.
- **G3 streaming-audio cost** — is the bgmusic-style channel cheap enough on
  Panther, or do we fall back to pre-rendered phrases there?
- **Sidecar availability** — graceful degradation when the box is unreachable
  (the game must keep playing as vanilla).

## Related

- `docs/KNOBS.md` — where the new cvars/flags get inventoried.
- `MISTAKES.md` — log the precache trap here once it bites for real.
- `CLAUDE.md` "Per-machine gating is a legitimate pattern" — the budget-cap
  gating mechanism.
