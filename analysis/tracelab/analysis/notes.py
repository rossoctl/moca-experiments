"""Speaker notes for the summary deck (analysis/deck.py). One entry per slide key.

Plain sentences, said aloud. Numbers come from out/tables and the results docs
(EXPERIMENTS.md, RESULTS-METAL.md, e16/RESULTS.md); when a table changes, check
the note that quotes it.
"""

NOTES = {

"title": """\
This deck covers two experiments, E15 and E16, and the trace analysis behind them.

The question both ask: on the same hardware, does SBX, which starts a fresh Firecracker microVM for every shell command, hold more concurrent coding-agent sessions than resident microVMs, where each session keeps one VM for its whole life?

E15 ran on two hosts: a small nested AWS instance with 4 vCPUs, as a preliminary run, and an AWS bare-metal machine with 96 vCPUs and 377 GiB of RAM. E16 reused the metal host with mostly idle sessions, to test whether SBX wins when sessions sit idle more of the time.

All results here are final.""",

"headline": """\
Four numbers frame everything that follows.

First, real coding sessions are mostly idle: a command runs only 9.5% of the time.

Second, the work is concentrated: 7% of calls run longer than 10 seconds, and they carry 87% of all the CPU work.

Third, on metal at that 9.5% duty cycle, SBX held 80 sessions and resident held 128.

Fourth, at a 1.5% duty cycle, in E16, both arms held at least 1,024 sessions under the sealed rules, and at least 1,536 when we removed an end-of-run artefact. They did not separate.

The short version: resident is never behind SBX, and what decides the limit is the latency of long commands, not memory.""",

"method_overview": """\
How the experiments work, before any results.

The workload is real. TraceLab v0.0.2 is a public dataset of 8,058 Claude Code and Codex sessions from 52 developers. An extractor turns it into a replay corpus: for every session, the ordered list of shell calls, each with its command class, its recorded run time and the idle gap to the next call. Gaps are capped at 30 minutes, so a developer who leaves overnight comes back 30 minutes later. Sessions with fewer than 20 calls are dropped, which leaves 4,147.

There is no LLM in the loop. A Go driver replays the sessions: it sends a call, waits for its result, sleeps the recorded gap, then sends the next one. Each call runs a real program of its class, like pytest, python, git or grep, inside the sandbox, sized to the recorded duration.

There are three arms. SBX is stock moca: a fresh VM per command. Resident infinity keeps one VM per session for its whole life. Resident 300 seconds reclaims a VM after 5 idle minutes. A control arm with no sandbox measures the driver itself.

Both microVM arms use the same Firecracker build, guest image, 1 GiB guest RAM and relay. The only difference is how long a VM lives.""",

"method_calibration": """\
Calibration and sealed predictions: this is what keeps the experiment honest.

Calibration runs once per host, before any measured rung. Every command in the library is timed five times inside a VM. Then each arm runs at N equals 1 over several seeds. A per-class probe runs each command class alone on an idle worker, 20 calls drawn from the corpus. That gives each arm two things: the median added latency of each class at N = 1, and B, the 95th percentile of each call's excess over its class median. B sets the latency limit. Calibration also runs the control arm at N = 128 to confirm the driver stays under 1% of host CPU.

Then the predictions are written from those numbers and sealed in a git commit before the first measured rung. Each prediction says what would falsify it. E15's AWS predictions were sealed at 708d62f, the metal ones at 3d653a2, and E16's at d7271aa. Sealed numbers are never edited afterwards. We report against them, including when they are wrong, and most of the numeric ranges were wrong.

Anything decided after seeing data is labelled supplementary: the 1-second limit, the post-seal SBX extension, the staggered end-sessions. Those are useful readings, but not verdicts.""",

"method_rung": """\
How one rung runs. A rung is one population size N.

At time zero the driver starts N slots, spread evenly over the first 60 seconds. Each slot draws a session from the corpus with a seeded random generator and starts it at a random call index, so the population is spread across the whole length of the sessions rather than all starting at their first call. No user may hold more than 15% of the live sessions. When a session ends, the slot immediately draws the next one, so the population stays at N.

Then comes the warm-up, which is not measured: 10 minutes on AWS, 20 minutes on metal. That lets resident VMs grow to their working size. Then the 15-minute measured window: only calls sent inside it are judged. Then a 5-minute grace period for in-flight calls to finish.

A rung holds when four conditions are all true in the window. One: no call fails. Two: nothing is refused, there is no out-of-memory kill and no memory-floor hit. Three: sessions keep their pace, median class pace within 10%. Four: the 95th percentile of per-call excess latency stays under max of 3 times B and 50 milliseconds.

Two repeat rules apply. If resident VM memory drifts more than 10% across the window, the rung is re-run once with double the warm-up, and the repeat counts. In E16, the deciding rungs, the last hold and the first failure, are re-run with a second seed, and a third when they disagree; the majority decides.

Between rungs the worker restarts and every workspace is reset, so no rung inherits state. The ladder climbs until the first failed rung; n_max is the last rung that held.""",

"duty": """\
This is the trace analysis: how busy sessions are.

Duty cycle is the share of a session's time with at least one command running. Each bar pair is one corpus variant. Default is the full corpus with gaps capped at 30 minutes. Short caps at 5 minutes, long at 2 hours. No-infra drops sessions that call docker, ssh or GPU tools. No-chains drops Codex sessions with long polled commands.

At the default point the whole corpus is busy 9.5% of the time. Codex sessions are about five times busier than Claude's: 19.2% against 3.8%. The cap matters: shorter gaps make sessions busier, longer gaps make them idler.

The takeaway for density: an idle session costs a resident VM memory but costs SBX almost nothing. That is the case for SBX, and it is what the experiments test.""",

"tiers": """\
How the work is distributed across calls.

We split calls by their CPU-carrying time: light under 1 second, medium 1 to 10 seconds, heavy over 10 seconds. The left panel compares each tier's share of calls with its share of work.

Three quarters of calls are light, but they carry only 2% of the work. The 7% of calls that are heavy carry 87% of it. The right panel checks that this does not depend on where we cut: moving the cuts to 0.5 and 5 seconds, or 2 and 20, keeps the heavy share between 80% and 91%.

This matters because, as we will see, those few heavy calls set the latency limit. When several of them overlap, everything else queues.""",

"classes": """\
Which kinds of command carry the work.

Dark bars are the share of work, light bars the share of calls. Interpreter calls, python scripts and the like, are 10% of calls but 29% of the work. Shell reads like grep and cat are 41% of calls but only 15% of the work. Writes and file reads are frequent and cheap.

Opaque calls, names TraceLab withheld, and host-infra calls such as docker and ssh are replayed as stand-ins of the same duration: half sleep, half interpreter. Together they are about a quarter of the work, so the stand-ins are a known fidelity limit, and the no-infra point bounds their effect.""",

"overlap": """\
Why the small AWS host saturated so early.

This is a model, not a measurement. It replays the driver's draw, the same session sampling, random start index and 60-second spread, over 20 seeds, and counts how many heavy calls run at the same time in the window.

At 16 sessions, four or more heavy calls overlap only 2.5% of the time. But each guest has one vCPU and the AWS host has four. That 2.5% is enough to queue every other call behind them and push the 95th percentile past the limit.

At 80 or 96 sessions, four or more heavy calls overlap most of the time, which is fine on 96 vCPUs. The model's window call counts match the measured rungs within their seed spread, which is how we checked it.""",

"ladder": """\
The E15 ladders, rung by rung.

Each line is one arm. The y-axis is the 95th percentile of excess latency, on a log scale. The dashed lines are each arm's limit, which comes from its own calibration. A cross marks the first rung that failed.

On the nested AWS host, left, every arm held 8 and failed at 16. On metal, right, SBX held up to 80 and failed at 96. Both resident arms held to 128 and failed at 160.

Every first failure on both hosts failed the latency condition only, with zero failed calls, nothing refused and host CPU at 9 to 13%. The host was nowhere near a resource wall. What fails is a tail of long CPU-heavy calls running a few percent slow: 3% of a 4-minute pytest run is 7 seconds of excess.""",

"nmax": """\
E15's n_max for every point and arm.

Left, the AWS preliminary run at every test point. The diamonds show the first-run reading where a drift repeat changed the verdict. Resident arms get repeated when their memory drifts; SBX never does, which is an asymmetry worth knowing. No point shows SBX ahead. Resident is ahead at no-infra, no-chains and mem512.

Right, metal at the default point: SBX 80, both resident arms 128. The open markers are supplementary readings, decided after the sealed ladders. With a flat 1-second latency limit every arm holds 192. With the latency test dropped entirely, keeping only failures, refusals and pace, SBX holds 320 and the resident arms 384 and 448. So even with latency removed, SBX holds the fewest.

Sealed prediction 8 said metal would show the largest SBX gain. The metal ratio, 80 over 128, is 0.625, below AWS's 1.0. Falsified.""",

"hosts": """\
What bare metal changes.

Left, the same rung on both hosts. At 16 sessions SBX's tail falls from 1,545 to 198 milliseconds, and resident's from 15,200 to 110. Nested virtualisation on the 4-vCPU host is most of the tail.

Right, per-call overhead at N = 1, measured in calibration. SBX pays 186 milliseconds per call on the nested host and 34 on metal: that is the cost of resuming and destroying a VM for every command. Resident pays slightly less than the recorded time, because its VM is already warm.

The mem512 bars are the memory-pressure point, where every session carries a 512 MiB dataset that scanning calls read. SBX re-reads it in a fresh VM on every scanning call: 1.6 seconds per call on AWS, 390 milliseconds on metal. Resident reads it once and keeps it in its page cache.""",

"turns": """\
An input to the next experiment, E15b, which would bundle all the shell calls of one LLM turn into one sandbox command.

Codex sends 1.78 shell calls per turn, and two thirds of its shell calls share a turn with another. Almost all same-turn Codex calls overlap in time. Claude sends 1.07 per turn, and only 11% of its calls share a turn.

So bundling would remove about one sandbox start in three overall, and about two in five for Codex. Note one caveat: the E15b spec's absolute turn counts could not be rebuilt from the DuckDB, though the shares agree with ours.""",

"e16_hypothesis": """\
E16 tests a specific hypothesis: when sessions are busy 2% of the time or less, SBX should hold more sessions than resident VMs.

The reasoning is sound on paper. A resident VM holds memory for its session's whole life. SBX holds a VM only while a command runs. Making sessions idler lowers each session's CPU and latency load, so both latency limits rise roughly as one over the duty cycle. But resident's memory per session does not fall. So at some low duty, resident should hit memory before SBX hits latency.

The method is E15's, on the same metal host, with three changes. The workload is the slice of the E15 corpus whose duty cycle is between 1% and 2%: 456 sessions, busy 1.5% of the time. Only SBX and resident infinity run. And moca's admission budget, which normally charges every VM its full 1 GiB, is set so high it never binds; physical memory is the only memory limit. That is the fairest test for resident. The ladder starts at 256 sessions, and the deciding rungs run with extra seeds.

The predictions were sealed on 8 November, before the first rung. Notably, we predicted the hypothesis would be falsified.""",

"e16_ladder": """\
The E16 ladders at 1.5% duty.

Solid lines are the sealed runs, dashed are the supplementary ones: the post-seal SBX extension to 1,536, and the resident re-runs with staggered end-sessions. Squares are runs that failed.

Neither arm ever failed on latency. SBX's tail rose to about 270 milliseconds against a 336 limit, resident's to about 280 against 395. Host CPU stayed at or below 23%.

The resident failures, at 896 seed 2, 1024 seed 1 and both 1280 seeds, were 9 to 24 calls that ended with exit minus 1. They were not latency failures. The next slides explain them: they come from the end of the run, not from the host.""",

"duty_memory": """\
What this slide shows: the same metal host at two duty cycles. Left bars: 9.5% busy, the full E15 corpus. Right bars: 1.5% busy, the E16 band. Blue is SBX, orange is resident infinity.

Left panel, sessions held. At 9.5% duty SBX held 80 and resident 128. At 1.5% duty both hold far more; hatching means a lower bound, because no rung failed.

Middle panel, memory against sessions. Resident's VM memory climbs about 0.1 GiB per session, to about 98 GiB on average at 1,024 sessions. SBX averages about 14 GiB at 1,024 and 18 GiB at 1,536, because its VMs live only while a command runs, plus a pool of warm standbys.

Right panel, memory ceiling against sessions held. Each pale bar is a calculation, not a measurement: usable memory, 373 GiB, divided by the memory one session used at that arm's limit. That is how many sessions memory alone would allow. The dark line is what the arm actually held.

The point to land: lower duty roughly halves SBX's memory per session, but hardly changes resident's, because a resident VM lives for the whole session. That is the mechanism behind the hypothesis. But resident is still far below its memory ceiling, so memory did not decide anything.

Caveats if asked. SBX's memory includes warm standby VMs; at 1,024 sessions most of its live VMs were standbys. The ceilings assume memory per session stays flat; the long rung shows resident VMs level off near 150 MiB after an hour.""",

"e16_vm_age": """\
Does a resident VM keep growing over a long session? This was the one effect that could let SBX win on memory, so E16 measured it before sealing.

One long rung ran resident infinity at 256 sessions for a 3-hour window. Each point is the median VM memory at that age; the band is the 95th percentile.

A fresh VM starts near 60 MiB, grows to about 120 by 20 minutes and 142 by an hour, then levels off near 147 to 150 MiB up to 3 hours. The 95th percentile stays near 230 MiB.

So resident memory is bounded. At 150 MiB per VM, 1,536 sessions need about 230 GiB, well inside 377. Memory does not bind in this range.""",

"e16_verdict": """\
The E16 verdict, under the three readings in the results document.

The sealed reading is the only one that is a verdict. SBX held its sealed top, 1,024, without failing. Resident held 1,024 and failed at 1,280. One ladder step is required for the hypothesis to hold; a tie falsifies it. So the hypothesis is falsified.

The post-seal SBX extension shows SBX holding 1,536 against resident's sealed 1,024. That looks like an SBX win, but it is not a sealed verdict, and resident's limit there is an instrument effect, explained next.

With that effect removed, staggered end-sessions, both arms hold 1,536, the top of the ladder. They do not separate.

On the predictions: the direction held, SBX's numeric range missed, prediction 2 was falsified because resident's failure was failed calls not latency, and the memory and driver predictions held.""",

"e16_worker": """\
What failed the resident runs: a limit in moca's worker, not the host.

At the end of the window, the driver ends every live session at once. For resident, that means one end-session command per session within about a second: around a thousand at once. SBX sends none, because its VMs are already gone.

A worker connection admits 320 commands: 256 running plus 64 queued. Everything beyond that is refused with busy, queue full, and the worker does not log it. The evidence is exact: on every sealed resident rung from 384 to 896, the refused end-sessions equal N minus 320.

From about 900 sessions, the refusals fill a 16-slot reserve for terminal frames within one second. The worker then drops the whole connection and reconnects, and every command in flight on it fails with exit minus 1, including unrelated window calls. That is the 9 to 24 failed calls.

When end-sessions are paced at 50 per second after the window, there are no refusals and no wedges, and every resident rung holds to 1,536. This is filed upstream as rossoctl/moca issue 705.""",

"binding": """\
The question: what binds before memory? This chart puts every candidate limit on one scale: each as a percentage of its own ceiling, at each arm's last rung that held.

Latency is the p95 excess divided by the arm's limit. CPU is host busy at the 95th percentile. Memory is the share of RAM in use. Disk is the 95th-percentile read rate against the volume's measured maximum of about 1 GB per second. Worker is the peak number of commands in flight against the worker's 320-command admission.

Latency is the closest to its ceiling in every case: 78% for SBX and 48% for resident at 9.5% duty, and 86% and 54% at 1.5% duty. Everything else has large headroom. CPU never passes 28%. Memory peaks at 24%, for resident at 1,024 sessions. Disk stays below 13%. In-window commands stay below 15% of the worker's 320.

So the answer is: not disk, not CPU, not memory. The latency tail binds first, in both arms. And the next slide shows why SBX reaches it sooner.

Note what is left out: moca's default admission rule, which charges 1 GiB per VM. It would refuse resident above about 365 sessions and SBX above about 500. Both experiments set it never to bind, on purpose, to measure the host and not the policy.""",

"coldstart": """\
Is it cold start? Partly, and in two different ways.

Left, the direct cost: added milliseconds per call at N = 1. On metal SBX pays 34 milliseconds per call at the default point, resident nothing. At 1.5% duty both are slightly below zero. That direct lifecycle cost is small on bare metal; it is far bigger nested, 186 milliseconds. The exception is mem512, where SBX's fresh VM must re-read the 512 MiB dataset on every scanning call: 390 milliseconds per call.

Right, the indirect cost, and this is the one that sets n_max. At equal N and equal host CPU, SBX's long calls run measurably slower than resident's: about 0.4% slower from the first rungs, 1.6% at 96 sessions, while resident is near zero until about 64. A fresh VM starts with a cold page cache and cold CPU caches. For a 4-minute call, one or two percent is several seconds, which is what pushes SBX's p95 past its limit before resident's.

So cold start binds SBX through the latency tail, not through its own lifecycle time.""",

"perf": """\
The hardware counters support the cold-state explanation. These were sampled with perf for 60 seconds every 5 minutes on the E15 metal climb rungs.

Left: the last-level cache miss rate. SBX runs at 8 to 10%, resident at 4 to 6%, at the same N and similar host CPU. Fresh VMs keep missing cache.

Middle: instructions per cycle stay high, above 4, in all arms. The CPU is not stalling broadly.

Right: the clock. The ratio is actual cycles over base-frequency cycles while a core runs; above 1 means turbo. It falls from about 1.5 times base to 1.34 as load rises.

Why the clock slows down: that is how Turbo Boost works. The chip shares one power and current budget across all its cores. With a few cores busy, each runs near the top turbo speed, about 3.8 gigahertz on this Xeon. As more cores wake up, each gets a smaller share, and the chip lowers every core toward its all-core turbo, about 3.2 gigahertz. The host was only 11 to 54% busy, but 25% of 96 threads is about 24 threads spread over most of the 48 physical cores, which is already near the all-core point. The curve flattens instead of falling below base, so the chip settled at all-core turbo; nothing points to overheating. Those gigahertz figures are from the spec sheet; we did not sample power or temperature.

What it means: all arms lose clock the same way at the same load, so it does not explain SBX against resident; the cache misses do. But it explains part of everyone's slowdown at high N, and part of that is a measurement effect: calibration timed each command on an idle host at top turbo, so at high load the same work gets roughly 16% fewer cycles per second and runs longer than planned, with nothing overloaded. A future run could pin the clock or calibrate under load to remove it.

So the limits are cache warmth and frequency, not saturation. No arm showed CPU pressure until resident 300 seconds at 512 sessions.""",

"summary": """\
Everything we learned, on one chart. Each row is one experiment; each bar is an arm's n_max; hatched bars are lower bounds, where no rung failed.

On the nested AWS host every arm tied at 8, limited by four vCPUs queueing long calls. On metal at 9.5% duty, resident held 128 against SBX's 80; both stopped on the latency tail of long calls running a few percent slow. With a 512 MiB dataset per session, both held 8, stopped by cold first scans. At 1.5% duty both arms held at least 1,024 under the sealed rules, and at least 1,536 once the run-end burst was removed.

Five lessons. One: resident is never behind SBX, on any host, point or reading. Two: the latency tail of long commands binds first, in both arms, long before CPU, memory or disk. Three: SBX reaches that tail sooner, because each fresh VM runs long calls a little slower, with cold caches. Four: lowering the duty cycle helps both arms about equally, so the arms do not separate, and memory never became the limit up to 1,536 sessions. Five: the most binding thing we found at high N was in moca itself, the worker's 320-command admission and the connection wedge, issue 705.

What would change the answer: moca's default admission rule. It charges every VM its full 1 GiB, and under it SBX would hold more sessions than resident, simply because SBX keeps fewer VMs alive. That is a policy result, not a host result.""",

"open": """\
What is still open.

E16 is censored: both arms held 1,536, the top of the ladder, so neither real limit on this host is known. Going higher needs more distinct sessions: above about 900, the 456-session band replays each trace two or three times at once, below the spec's 60% distinct-trace threshold.

The moca worker issue, 705, should be fixed: refusals should be logged, and a burst of refusals should not drop unrelated commands.

E15b, per-turn bundling, is specified and approved but not run. It targets exactly the cost this deck identifies, SBX's per-command cold state.

And two analysis caveats: the E15b turn counts do not reproduce from the dataset, though the shares do, and our overlap model is a statistical match to the driver, not the same random sequence.""",
}
