# CPU power workaround integration checks

`make test` builds StillCore and checks its daemon packaging,
signature requirements, XPC rejection of unrelated clients, refusal to run the
helper without root, and the child's process group. It also exercises connection
and startup timeouts, late replies, approval changes, and battery heartbeat
confirmation. It repeats the checks with a relative argv[0]
like launchd uses. Registration tests use a fake SMAppService; no daemon is registered.

The following checks require macOS 27+ and administrator approval of the bundled
daemon. Use **Start** in the CPU Power Updates popover, then approve it
in **System Settings → General → Login Items & Extensions**. Release distribution
uses the existing Developer ID signing and notarization workflow.

1. Before enabling, verify the notice appears above Power. Open its popover and
   verify the explanation and Start action. No helper or child should be running.
2. Start the service. Verify `.starting` shows a spinner, then approval instructions
   appear if required. After approval, the notice disappears only after the helper
   confirms the child started.
3. Inspect the exact helper and its child with
   `ps -axo pid,ppid,pgid,args`. Expect one helper and one child with arguments
   `powermetrics --samplers gpu_power -i 400`, and matching process groups. Do not
   confuse them with a separately started powermetrics process.
4. Hide the StillCore panel: sampling continues. Quit using StillCore's Quit or
   power button: both the helper and its child disappear. Reopen StillCore:
   sampling starts without another Start action or registration removal.
5. Force-quit that StillCore process. Verify the helper and its child disappear.
6. Open two instances of the same built app. Verify they share one child. Quitting
   one instance leaves sampling active; quitting the last stops it.
7. Terminate only the helper's child. Verify the notice returns with an error,
   sampling does not restart in a loop, and Start starts a fresh child.
8. Terminate the helper with SIGTERM, then repeat with SIGKILL. Verify the child
   disappears in both cases and the running app exposes the failure.
9. Revoke the daemon's approval in System Settings. Verify sampling stops and
   the app offers the approval instructions. Rebuild and relaunch while approval
   is revoked: no automatic registration attempt or Update error should appear.
   Reapprove and verify the changed build is registered before sampling resumes.
10. On macOS below 27, verify there is no notice, helper connection, or daemon
    registration initiated by StillCore.

Do not kill an existing unrelated StillCore or powermetrics process during these
checks. Debug and Release both use `com.github.homm.StillCore.PowerMetrics` and
`com.github.homm.StillCore.BatteryTracker`.

11. Rebuild a helper without changing the version and relaunch. Verify the old
    helper stops before the new registration starts it. Relaunch without rebuilding:
    neither service should be registered again.
12. Move the unchanged app and relaunch. Verify helpers still work without
    re-registration. Launch a build with different binaries and verify it
    re-registers the services. If macOS requests approval, verify the app reports
    it rather than claiming the helper is running.
13. If a registration fails after unregistering, relaunch and verify the service
    remains stopped and offers Start. Verify pressing that action
    retries registration without a false success state.

14. Make the PowerMetrics helper accept a connection without replying to start.
    Verify `.starting` becomes `.stopped` with an error after five seconds. A late
    reply must not restore `.running` or affect a subsequent attempt.
15. Start BatteryTracker from its popover. Verify the same Start / approval / spinner
    states, followed by `.running` only after a new healthy heartbeat. An old record
    in storage must not confirm a restarted helper.
16. In a test battery helper, delay heartbeat updates after registration completes.
    Verify a 15-second confirmation timeout leaves `.stopped` with an error and Start.
    Restore updates and verify a new healthy heartbeat restores `.running` without another
    registration attempt. A stale heartbeat or helper error must restore the warning.
17. Repeat approval revocation and reapproval for the battery agent. A stored heartbeat
    must not report `.running` while approval is missing. Verify battery percentages,
    discharge history and energy settings still work, and a current-battery read error
    does not mark a tracker with a healthy heartbeat as stopped.

Confirmation timeouts start after registration completes. Waiting for the macOS
registration API itself has no application-defined timeout.
