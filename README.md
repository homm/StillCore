# StillCore

StillCore is built for continuous Apple Silicon monitoring with low overhead. It stays in the macOS menu bar, quietly tracks what the Mac is doing, and is ready when something suddenly feels off: the laptop gets warm, battery drain jumps, or a background task briefly spikes power usage.

Main features:

- Full-system power chart (including display, speakers, and peripherals). Useful when a 5 W CPU increase turns into a 10 W system increase.
- Chip, CPU and GPU power charts for more precise diagnostics.
- CPU and GPU frequency and usage on the combined chart.
- Temperature charts.
- Adjustable update interval from 100 ms to 10 seconds.
- Quick menu bar access with an optional always-open window.
- Battery session tracking, such as 15% used over 2 hours since the last charge.

<img src="docs/app.png" alt="StillCore app screenshot" width="487">

StillCore is for everyday monitoring rather than deep profiling. It is built on top of [macmon](https://github.com/vladkens/macmon), which provides the core Apple Silicon metrics.


## Requirements

- macOS 14 or newer
- Apple Silicon Mac


## Download

Prebuilt downloads are available on the GitHub releases page:
https://github.com/homm/StillCore/releases


## License

StillCore is released under the MIT License. The metrics core is built on
[macmon](https://github.com/vladkens/macmon), which is also distributed under
the MIT License.


## Why I Built It

I often work on a laptop and want to understand what is happening with energy usage. I used MX Power Gadget for this, but later found that it reports misleadingly low power for itself while consuming a lot of CPU power in practice[^mx-power-gadget]. That led me through several monitoring experiments, and eventually to the decision that I could build something better for my own workflow.

During development, I paid attention to StillCore's own footprint. The table below shows power usage while running different monitoring apps as `CHIP`: `CPU` + `GPU` in watts. For example, the idle baseline without any monitoring apps is `0.02`: `0.00` + `0.00`.

| App | Mode | 100ms update interval | 1 sec update interval |
| --- | --- | --- | --- |
| | | `CHIP`: `CPU` + `GPU` | `CHIP`: `CPU` + `GPU` |
| **StillCore** | In tray<br>Interactive | `0.03`: `0.01` + `0.00`<br>`0.12`: `0.03` + `0.02` | `0.02`: `0.01` + `0.00`<br>`0.04`: `0.02` + `0.00` |
| **Stats** 2.12.12 | In tray<br>Interactive | -<br>- | `0.04`: `0.01` + `0.00`<br>`0.06`: `0.02` + `0.00` |
| **iStat Menus** 7.2 | In tray<br>Interactive | -<br>- | `0.02`: `0.00` + `0.00`<br>`0.03`: `0.01` + `0.00` |
| **Activity Monitor** macOS 15.7.5 | In tray<br>Interactive | -<br>- | `0.12`: `0.09` + `0.00`<br>`0.16`: `0.12` + `0.00` |
| **MX Power Gadget** 1.6.4[^mx-power-gadget] | In tray<br>Interactive | -<br>- | `2.78`: `2.67` + `0.00`<br>`2.80`: `2.68` + `0.00` |

[^mx-power-gadget]: MX Power Gadget uses `powermetrics` for its measurements, but according to this [Habr article in Russian](https://habr.com/ru/articles/858736/), it starts a new `powermetrics` process for each sample. Because `powermetrics` has a relatively expensive startup phase, the utility can consume a few watts in practice even when its own charts show near-zero power.


## Build From Source

Building from source requires Xcode with Swift 6 support and network access for Swift Package dependencies.

Create a local DMG from source:

```sh
make dmg
```

This creates the Release `StillCore.dmg`.

Remove build artifacts:

```sh
make clean
```


## Development

Development builds use `CONFIGURATION=Debug` by default.
Pass `CONFIGURATION=Release` to build and run the Release configuration with the same command.

Install repository-managed Git hooks once per checkout:

```sh
make install-hooks
```

Build and run from the terminal:

```sh
make run
```

Build and open the app bundle:

```sh
make open-app
```

Launch Instruments Time Profiler for a Release build:

```sh
make profile
```


## Local Metrics Core Development

Use `LOCAL=1` when you want to develop or test StillCore together
with local changes in the metrics collection core.

Additional requirements:

- Rust toolchain with Cargo
- Xcode command line tools
- Local checkouts of `macmon` and `macmon-bindings` next to this repository

Clone the sibling repositories and build the local `macmon` xcframework:

```sh
cd ..
git clone https://github.com/homm/macmon.git
git clone https://github.com/homm/macmon-bindings.git
cd macmon
make xcframework
cd ../StillCore
```

Build and open StillCore against the local metrics core:

```sh
LOCAL=1 make open-app
```

`LOCAL=1` uses `StillCore.local.xcworkspace`, expects `../macmon/dist/CMacmon.xcframework`,
and uses the sibling `../macmon-bindings` checkout.
