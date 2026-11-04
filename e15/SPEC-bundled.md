# E15b — bundled commands: does per-turn bundling narrow resident's warm-VM advantage?

Version: 0.1, 2026-11-04
Status: **Design. Approved by the user 2026-11-04. Not built; runs after E15's metal ladders.**
Parent: `e15/SPEC.md` (E15). E15b reuses E15's instrument unchanged except where this document
says otherwise. Section references like "§8" are to E15's spec.
Rig: the metal host of E15 §13 (AWS m7i.metal-24xl), after E15's metal ladders finish.

---

## 1. The question

**When an agent sends all the shell commands of one LLM turn as one sandbox command (one bundle,
one Exec), how much of resident VMs' warm-VM advantage over SBX goes away?**

A resident VM keeps its page cache, its imported modules and its process state between commands.
SBX starts every command in a fresh microVM from the golden snapshot. Bundling gives SBX that warm
state for the length of one bundle: the second and later commands of a bundle run in the VM the
first one warmed. It cannot help across turns, because the next turn's commands depend on the
model reading this turn's output.

### 1.1 Why now

- E15's calibration showed where SBX pays for its fresh VM: +186 ms per call on the nested AWS
  host and +34 ms on metal at the default point, and +390 ms on metal at mem512, where every scanning call
  re-reads a 512 MiB per-session dataset. At mem512 SBX fails at N = 8 on an idle host: each new
  session's first scans are cold (about 2.5 s added), and SBX pays the cold read once per VM, not
  once per session.
- Coding agents reach SBX through hosted MCP tools (SBX wave 0). An MCP tool can take several
  commands in one call, and the sbx-mcp spike found fewer Execs to be the main latency lever.
- ADR-0035 keeps SBX per-Exec and gates command coalescing. E15b measures what per-turn coalescing
  buys, on the same workload and the same host as E15.

### 1.2 How much there is to bundle

From the TraceLab v0.0.2 DuckDB (all shell-command calls, before E15's session filters):

| provider | turns with a shell call | shell calls | calls per turn | calls in turns with ≥ 2 |
|---|---|---|---|---|
| Codex | 117,638 | 200,521 | 1.70 | 62.7% |
| Claude | 62,185 | 66,983 | 1.08 | 12.5% |
| all | 179,823 | 267,504 | 1.49 | 50.1% |

So per-turn bundling removes about one Exec in three overall, and about two in five for Codex.
Within a Codex turn the shell calls mostly overlap in time (96.9% of consecutive pairs start before
the previous one ends); E15 replays that overlap, a sequential bundle does not (§3.2).

## 2. Goals, non-goals

**Goals**
- One number per arm and point, as in E15: `N_max` (primary and absolute verdicts, §8), at a
  bundled point, compared with the same arm's unbundled `N_max` from E15's metal run.
- The mechanism, measured: Execs per session-hour, cold scans per window (mem512), per-call added
  latency at N = 1, p95 excess at each rung.

**Non-goals**
- No LLM in the loop, as in E15. Bundles come from the recorded turns.
- No bundling across turns, and no speculative or batched execution of future commands.
- No parallel steps inside a bundle (§3.2).
- No change to moca: a bundle is one ordinary `Exec` whose script runs several commands.

**Anti-goals**
- A bundled point that hides a real cost. A session's first cold read stays in the replay; no
  pre-warming of datasets or caches (the E15 mem512 ruling).

## 3. Design

### 3.1 The bundled corpus

The extractor gains one option, `--bundle turn`. For each session, consecutive replayed calls of the
same recorded turn (`round_pk`) become one bundle:

- **Members** keep their recorded order (emit time, then `tool_index`).
- **Script:** the members' scripts are joined in order into one guest script, with E15's per-step
  exit checks kept for each member. A member's failing exit does not stop the bundle (the agent
  receives every member's output).
- **Duration and work:** the sum of the members' `dur_ms` and `work_ms`.
- **Offset:** the first member's offset. **Gap:** the last member's gap.
- **Output size:** the sum of the members' `out_bytes`.
- **Codex polled chains (§5.3) are never bundled.** A chain spans turns; it stays its own call.
- **Frame limit:** a bundle whose encoded request would exceed the guest agent's limit (E15's
  30,720-byte check) is split at member boundaries into the fewest bundles under the limit.
  The count of split turns is reported.
- **mem512:** each scanning-class member keeps its own `cat /workspace/data.bin` step. In SBX the
  first one in a bundle reads cold and the rest hit that VM's page cache. That is the effect
  under test, so it is left to the guest, not modelled by the driver.

The extractor reports, per corpus: turns, bundles, members per bundle (mean, p50, p95, max),
the Exec reduction factor (calls ÷ bundles), split turns and unbundled chain calls.

### 3.2 Sequential members (our call)

A bundle runs its members one after another in one shell. That is what a "run these commands"
MCP tool does, and it is the simplest bundling to build. Codex's overlapping same-turn calls
therefore lose their overlap: that cost belongs to bundling and is reported as the change in
session pace at N = 1. A parallel-member bundle is a possible later variant, not part of E15b.

### 3.3 Class of a bundle

E15's conditions 3 and 4 are class-matched (§8). A bundle's class is the class of its member with
the largest `work_ms` (ties: the first such member). The per-class N = 1 probe draws bundles from
the bundled corpus's distribution for each class. (Our call: the dominant member sets most of a
bundle's run time, and a per-combination class would leave most combinations undercovered.)

### 3.4 Points and arms

| point | corpus | arms |
|---|---|---|
| **bundled** | E15's default corpus, bundled by turn | SBX, resident ∞ |
| **bundled-mem512** | E15's mem512 point, bundled by turn | SBX, resident ∞ |

Resident 300 s is not run: at E15's default it tracked resident ∞ within one step on every host.
The comparison rows come from E15's metal run (default and mem512, same arms, same host).

### 3.5 Procedure

The E15 metal procedure, unchanged (§13): warm-up 1200 s, 15-minute window, footprint drift on
summed VM memory, the extended ladder, worker restart and workspace reset between rungs, the
memory guards, the relay restart and attach check.

1. Build the two bundled corpora; record their reports.
2. Calibration (§10.1) for the two bundled points: N = 1 baselines (3 seeds) and the per-class
   probe per arm; an N = 8 calibration rung per arm. The command library is E15's metal library.
3. Write the predictions (§4) from E15's metal results and this calibration; seal them before the
   first ladder rung.
4. Ladders: each arm and point from N = 1 to the first failed rung.
5. Record: `e15/results/metal-bundled/`, and an E15b section in the metal results.

Rig time on metal: about 6 h of calibration and about 1.5 days of ladders (the default-like point
runs to the CPU wall, about N = 400; the mem512 point is short for SBX).

## 4. Hypotheses (to be turned into sealed predictions after calibration)

- **B1, default CPU wall unchanged.** Bundling does not move either arm's primary `N_max` by more
  than one ladder step. On metal an SBX VM lifecycle costs 0.031 core-s against about 3.6 core-s of
  recorded work per call, so removing a third of the VMs saves under 1% of CPU.
- **B2, SBX's per-call overhead falls.** SBX's N = 1 added latency per recorded call falls by about
  the Exec reduction factor (from +34 ms towards +23 ms on metal); resident's does not change
  materially.
- **B3, mem512 cold scans fall but do not vanish.** SBX's cold scans per window fall (a bundle's
  second and later scans are warm), but each session's first scan of each turn stays cold, so SBX's
  mem512 `N_max` stays well below resident ∞'s.
- **B4, resident's memory bound unchanged.** Resident ∞'s mem512 `N_max` stays within one step of
  E15's metal value: bundling changes how often a resident VM runs, not what it holds.
- **B5, pace cost of serialising Codex turns.** The bundled point's N = 1 median session pace
  (relative to the unbundled default) rises by a few percent for Codex sessions and stays flat for
  Claude sessions.

## 5. Risks and open items

- **Bundles are an upper bound on per-turn coalescing.** Real agents do not always know a turn's
  commands up front; some would still go one at a time. E15b measures the best case of per-turn
  bundling.
- **Error semantics.** Running every member after a failed one matches a batch MCP tool, but an
  agent that stops at the first failure would run less. Members after a failed member are counted.
- **Class key.** The dominant-member class (§3.3) is a choice; the report also gives p95 excess by
  bundle size.
- **Same host, different day.** E15b's comparison rows are E15's metal ladders on the same host.
  If the host is replaced in between, both arms' unbundled default rungs at N = 1 and N = 8 are
  re-run as a check.

## 6. Left to the builder

- How `--bundle turn` is wired into `e15/extract` and the driver's script joiner.
- The split algorithm under the frame limit, as long as it splits at member boundaries.
- The report's layout.
