# Bulk Crew Promotion

Bulk Crew Promotion adds map right-click actions for promoting and reshuffling
pilots/captains across many player ships at once.

The vanilla map already has a useful one-ship action: replace the current pilot
with the best available crewmember on that ship. This mod keeps that spirit, but
adds bulk tools for large empires where doing it ship by ship becomes menu work.

## Requirements

- **SirNukes Mod Support APIs** ([link](https://www.nexusmods.com/x4foundations/mods/503)).
  This is a hard dependency; it provides the Lua loader, interact-menu API, and
  simple menu/options helpers.

## Actions

| Action | Scope | Notes |
|---|---|---|
| **Promote best crew** | Selected ships | Promotes the best on-board service/marine crewmember on each selected ship. |
| **Promote best crew on all ships** | Whole empire | Same local promotion pass, but for every player ship. |
| **Reshuffle captains, empire pool** | Selected ships | Immediate reshuffle using lax defaults. Preserves the original quick behavior. |
| **Reshuffle captains with config, empire pool** | Selected ships | Opens the reshuffle config window, then runs against selected ships. |
| **Reshuffle captains on all ships** | Whole empire | Opens the reshuffle config window, then runs against every eligible player ship. Can also include station managers (see below). |

Selected-ship actions appear when right-clicking a player ship, or when
right-clicking free sector space while player ships are selected. Whole-empire
actions are shown on the player HQ by default.

The mod-wide Extension Options menu has a few mod-level options:

- **Show whole-empire actions only on HQ.** Enabled by default. Disable it to
  show whole-empire actions on every player-owned station.
- **Debug logging.** Optional; useful for troubleshooting reshuffle decisions.
  Reason logging can be grouped, per-decision, or disabled.

## Promote Vs Reshuffle

|   | Candidate pool | Movement | Best for |
|---|---|---|---|
| **Promote** | Each ship's own service + marine crew | None, same-ship promotion | Quick local cleanup |
| **Reshuffle** | Player empire service + marine + unassigned crew | Cross-ship assignment through `AssignHiredActor` | Moving the best pilots to ships that need them |

Promote does not move crew between ships. Reshuffle builds an empire-wide
candidate pool and assigns better candidates to target captain slots.

Existing captains, managers, ship traders, and other assigned-post NPCs are not
used as reshuffle candidates.

## Configured Reshuffle

Configured reshuffle opens a run-options window before moving anyone. The same
window can also be opened from Extension Options to edit the default values used
for future configured runs.

The immediate selected-ships reshuffle does **not** read these options. It uses
lax Lua defaults so the old one-click behavior stays fast and broad.

Implemented configured options:

- **Target ship purpose filters.** Include or exclude military, miners, traders,
  builders, salvage ships, auxiliaries/resuppliers, and other ship purposes.
- **Donor ship purpose filters.** The same purpose filters, but for ships that
  may donate candidate crew.
- **Target and donor size filters.** Include or exclude S, M, L, and XL ships
  independently for target and donor sides.
- **Candidate role filters.** Allow or disallow service crew, marines, and
  unassigned personnel as candidates.
- **Donor protection.** Keep a minimum percentage of service crew and marines on
  civilian donors and military donors, tracked separately.
- **Recipient safety.** Require target ships to be above configured hull and
  shield percentages.
- **Improvement thresholds.** Require a minimum raw piloting improvement and/or
  minimum combined pilot-assignment score improvement.
- **Fleet filters.** Optionally restrict candidates to ships under the same
  commander, or target only ships without a commander.
- **Additional target filters.** Optionally target only ships without a captain.
- **Marine protection.** Preserve marines whose boarding skill is at or above a
  configured threshold.

### Station Manager Reshuffle

The whole-empire reshuffle config window includes a **Try to reshuffle all
station managers** checkbox. This option only appears in the HQ menu — not in
selected-ship menus — because the game does not currently support selecting
multiple stations. When enabled, station manager posts are included as
reshuffle targets alongside ship captain slots: the same empire-wide candidate
pool is used, but candidates are ranked by management skill instead of piloting.
If every target ship is excluded by purpose or size filters, the reshuffle will
still run for station managers alone.

## Reshuffle Details

1. Target slots come from selected ships or all player ships, depending on the
   action.
2. Ships whose current pilot already has capped piloting skill (`15/15`) are
   skipped.
3. Ships with no non-pilot crew capacity and an already assigned captain are
   skipped.
4. Candidates are collected from allowed donor ships and allowed roles.
5. Candidates are sorted by raw `piloting` skill first. Combined assignment
   skill for `aipilot` is the tie-breaker.
6. For each target, the script asks the engine for the candidate's combined
   skill on that specific pilot post and only applies configured improvements.
7. Large reshuffles run over `onUpdate`, one target slot at a time, so the game
   remains responsive instead of freezing for one long synchronous pass.

## Full Ships

When the target ship is full, reshuffle tries a small workaround:

1. Pick one low-value service/marine crew member on the target ship.
2. Move that person to the donor ship, preserving role when possible.
3. Wait one second.
4. Retry assigning the chosen candidate as the target captain.

If the donor has no room, that donor is skipped for the current target and the
script keeps searching. If the target has no movable service/marine crew, the
slot is skipped.

This is deliberately conservative. It does not move existing captains,
managers, ship traders, or other special-post NPCs out of the way.

## Caveats

- **Reshuffle is not undoable.** It moves crew through the same engine path as
  normal personnel assignment.
- **Selected scope includes the right-click target.** Lua deduplicates the
  right-clicked object and selected ships, then filters invalid sector/free-space
  targets before touching sensitive C API calls.
- **Busy pilots are retried.** If the engine reports
  `previouspilotbusy`, the assignment is queued and retried on a delayed
  schedule (after 10s, then 60s, then 120s). The target ship is only skipped if
  the pilot is still busy after the last retry.
- **Debug logging is off by default.** Enable it from Extension Options if you
  need troubleshooting output. The default grouped mode summarizes donor skips,
  target skips, candidate skips, delayed retries, and assignments without
  flooding the log.

## Credits

- Inspired in part by **Zoinks Captain Shuffle**.
- Built on **SirNukes Mod Support APIs**.
- By VasiliyTemniy.

## Source

https://github.com/VasiliyTemniy/x4-foundations-bulk-crew-promotion
