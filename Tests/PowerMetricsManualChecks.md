# Helper integration checks

`make test` builds StillCore and checks its daemon packaging,
signature requirements, XPC rejection of unrelated clients, refusal to run the
helper without root. It also exercises connection
and startup timeouts, late replies, approval changes, and battery heartbeat
confirmation. It repeats the checks with a relative argv[0]
like launchd uses. Registration tests use a fake SMAppService; no daemon is registered.

The PowerMetrics daemon remains bundled and its existing registration is retained,
but StillCore no longer initializes its service or connects to it at startup. Its
XPC start request only acknowledges the connection; it launches no child process.

1. Launch StillCore with the daemon unregistered, registered, and awaiting approval.
   Verify there is no CPU Power Updates notice, popover, or Start action.
   Launching the app must not register, unregister, connect to, or start the daemon.
2. Inspect the app's processes with `ps -axo pid,ppid,pgid,args`. Launching StillCore
   must not start PowerMetricsHelper or powermetrics. Do not stop existing unrelated
   processes to perform this check.
3. Rebuild and relaunch with an existing PowerMetrics registration. Verify the app
   leaves it unchanged and requests no new approval for this daemon.

The remaining manual checks concern BatteryTracker. Debug and Release use the
same `com.github.homm.StillCore.BatteryTracker` service label.

4. Rebuild the battery helper without changing the version and relaunch. Verify the
   changed build is registered. Relaunch without rebuilding: it must not register again.
5. Move the unchanged app and relaunch. Verify the battery helper works without
   re-registration. If a changed build requires approval, verify the app reports it.
6. If battery helper registration fails after unregistering, verify the service
   remains stopped and offers Start, and that pressing Start retries registration.
7. Start BatteryTracker from its popover. Verify the Start / approval / spinner
    states, followed by `.running` only after a new healthy heartbeat. An old record
    in storage must not confirm a restarted helper.
8. In a test battery helper, delay heartbeat updates after registration completes.
    Verify a 15-second confirmation timeout leaves `.stopped` with an error and Start.
    Restore updates and verify a new healthy heartbeat restores `.running` without another
    registration attempt. A stale heartbeat or helper error must restore the warning.
9. Repeat approval revocation and reapproval for the battery agent. A stored heartbeat
    must not report `.running` while approval is missing. Verify battery percentages,
    discharge history and energy settings still work, and a current-battery read error
    does not mark a tracker with a healthy heartbeat as stopped.

Confirmation timeouts start after registration completes. Waiting for the macOS
registration API itself has no application-defined timeout.
