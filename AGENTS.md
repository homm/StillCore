# Project Instructions

## Code Style

- Do not use `guard` in new code. Use `if` instead.

## Build Commands

Useful `make help` commands for development:

- `make app` — build `StillCore.app`
- `LOCAL=1 make app` — build with local workspace and local `macmon` xcframework
- `make run` — build and run `StillCore` in the current terminal
- `make open-app` — build and open `StillCore.app`
- `make profile` — build `StillCore` and launch Time Profiler
- `make benchmarks` — run charts benchmarks
- `make clean` — remove `.build`

FYI:

- `make release` — build a Release `StillCore.dmg`, submit it for notarization, then staple and validate it
- `make dmg` — build a local Release `StillCore.dmg` suitable for local running

## Verification

After any code changes, verify the result by running the appropriate build command from `make`. Prefer the narrowest command that proves the change, but always run a real build check before finishing.

## Direct xcodebuild Usage

If a task requires a one-off or specific `xcodebuild` invocation, use the same `XCODEBUILD_FLAGS` and `-derivedDataPath .build` defined in `Makefile`. This keeps ad hoc builds aligned with the normal project build. Use `make clean` if the build state needs to be reset first.
