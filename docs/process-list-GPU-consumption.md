# GPU consumption in the process list

## What the columns measure after the rollback

**GPU %** uses the original IORegistry counter. For each child of an `IOAccelerator` service, StillCore reads the PID from `IOUserClientCreator` and sums `AppUsage[].accumulatedGPUTime` for that PID. The displayed percentage is 100 times the change in attributed GPU nanoseconds divided by elapsed nanoseconds, capped at 100%. Missing counters or an invalid baseline produce no reading. The attribution limit described below still applies.

**Power** shows CPU watts. StillCore divides the change in the process's `ri_energy_nj` by elapsed nanoseconds. A compute-heavy GPU workload can therefore show very little Power in its process row while the device GPU power graph rises by roughly 20 W. The graph uses device-wide GPU energy from IOReport. [XNU CPU energy accounting](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md)

## Workloads and controls

The investigation ran on an Apple M4 Pro with 20 GPU cores and macOS 27.2. The original report used `macmon stress gpu`. The device graph stayed near 20 W while the watts attributed to the stress process varied. Moving a window sometimes coincided with its reported GPU % approaching zero.

To separate a real slowdown from a change in attribution, a second test ran a fixed Metal compute kernel without rendering or presenting frames. It submitted one command buffer at a time, waited for completion, counted completed buffers and summed their GPU end time minus start time. Sampling covered idle, load and cooldown at roughly one-second intervals. Moving the floating StillCore window introduced compositor work during the load. Throughput and command duration are independent checks on whether the workload slowed down. Neither measures watts or exclusive ownership of all GPU cores. [Metal command buffer timing](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime)

## Observations

| Measurement | Result |
| --- | --- |
| Window movement during compute | In one run the process reading fell from 72–92% to about 8–11%. Throughput stayed near 210–218 buffers per interval, with about 0.96 s of command execution. |
| Raw IORegistry attribution | In one interval the test received about 10%, WindowServer 84% and other clients the remainder of roughly 99%. The test still completed 212 buffers in that interval. The shift was visible in the raw client counters before StillCore calculated percentages. |
| Independent time measurements | In a subsequent run, steady intervals had 211–215 completed buffers and 0.955–0.961 s of Metal command time. The process reading ranged from 2.6% to 42.8%, while its resource coalition reported 90.7–99.5%. |
| Device and coalition energy | In one run the device averaged 19.68 W, the test coalition 13.94 W and all measured coalitions together 19.72 W. Most of the remainder was attributed to the WindowServer coalition. In another run the device averaged 22.26 W and WindowServer's coalition 12.27 W. These are separate runs. |
| Sampling boundaries | The sum of coalition rates could briefly exceed device power over a one-second interval even when their averages agreed over the run. Boundary timing can affect a single reading, but it does not explain the sustained difference in process GPU time. |

The raw counters establish where the discrepancy first appears. WindowServer's attributed share rises while the compute workload continues at nearly the same rate. The exact AGX driver rule for overlapping workloads remains unknown. The measurements also do not establish how many physical watts either process would have consumed in isolation.

## Approaches investigated

| Source or approach | Result and limitation |
| --- | --- |
| Coalition GPU energy distributed among PIDs (implemented, tested, then removed) | The prototype read the resource coalition ID with `proc_pidinfo`, read `gpu_energy_nj` with `coalition_info_resource_usage`, and allocated each interval's watts in proportion to each PID's raw GPU-time delta within its coalition. It added that estimate to CPU watts. Tests checked conservation and CPU-only fallback for missing, reset or unstable samples. A real Metal load confirmed a nonzero GPU contribution. Neither check establishes the accuracy of individual rows. |
| Diagnosing the allocation | During the macmon test the process often held 97–99% of its coalition's observed GPU time, with stable membership and no fallback. Its watts still fluctuated with the coalition energy counter. Within a shared coalition, the unreliable IORegistry time split adds a second source of error. |
| Energy billed between coalitions | The separate counters for work done on behalf of others and work others did on a coalition's behalf had zero deltas for the test and WindowServer in the checked intervals. Applying those fields would not recover the difference observed here. [XNU coalition fields](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/coalition.h) |
| Mach task GPU time | `TASK_POWER_INFO_V2` succeeded for the instrumented process but returned zero GPU time throughout the load. The published ARM64 implementation returns zero for per-thread GPU statistics and charges GPU time to the resource coalition. [XNU ARM64 accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/arm64/machine_routines.c) |
| Resource coalition GPU time | The independent `coalition_resource_usage.gpu_time` counter tracked the Metal workload much more closely. Several PIDs can share a coalition. Also, the test coalition and WindowServer could both report substantial activity in the same interval, so their percentages need not sum to 100%. It is a candidate for group-level reporting. |
| Metal command buffer timestamps | Effective as a reference inside the test executable. Reading those timestamps requires access to its command buffers. StillCore has no equivalent reference for every other process it lists. |
| Distributing device watts by GPU time (considered only) | IOReport provides the device total. Time alone cannot determine energy per PID because workloads can overlap and have different power costs. Such a split would introduce another estimate. |
| Three-second smoothing (considered only) | Averaging would delay changes and preserve the underlying attribution error. It was not applied. |

For a short reproduction, run `macmon stress gpu`, compare its row with the device GPU graph, then drag a window while the workload continues. To distinguish a slowdown from an attribution change, repeat with an instrumented compute workload and compare completed commands, Metal duration, raw IORegistry deltas for the test and WindowServer, and coalition time and energy over the same intervals. Across the sources checked, no verified method yielded both GPU activity and GPU watts for each arbitrary PID.
