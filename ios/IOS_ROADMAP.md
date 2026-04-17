# iOS Roadmap

## Status / Scope
iOS is still effectively a v1 client: it parses only QR `v=1`, talks raw tmux over SSH, and bypasses the gate protocol entirely. Android and the Mac CLI have already moved to the v2 gate and device-permission model. The goal of this roadmap is to move iOS onto that same gate/v2 permission model first, then close the remaining release-facing UX and security gaps.

## Reference Points

### Mac CLI / gate authority
- `bin/handoff`
  - `cmd_pair`
  - `cmd_gate`
  - `cmd_devices_list`
  - `cmd_devices_rm`
  - `cmd_devices_edit`
  - `cmd_devices_renew`
  - `cmd_devices_log`
- `lib/handoff-common.sh`
  - `derive_verification_code`
  - device registry helpers
  - authorized_keys forced-command helpers

### Android reference implementation
- `android/app/src/main/java/com/handoff/app/data/SshManager.kt`
- `android/app/src/main/java/com/handoff/app/data/ConnectionConfig.kt`
- `android/app/src/main/java/com/handoff/app/data/ErrorMessages.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/ScanScreen.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/VerificationScreen.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/SessionsScreen.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/TerminalScreen.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/SettingsScreen.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/BiometricGateScreen.kt`
- `android/app/src/main/java/com/handoff/app/MainActivity.kt`

### iOS current state
- `ios/Handoff/Sources/Models/ConnectionConfig.swift`
- `ios/Handoff/Sources/Models/QRCodePayload.swift`
- `ios/Handoff/Sources/Services/SSHManager.swift`
- `ios/Handoff/Sources/Services/TerminalChannel.swift`
- `ios/Handoff/Sources/Services/TailscaleManager.swift`
- `ios/Handoff/Sources/Views/SessionsView.swift`
- `ios/Handoff/Sources/Views/TerminalView.swift`
- `ios/HANDOFF.md`
- Host-key TOFU work lives on the local `ios-host-key-verification` branch. It is ahead of `main`, but it does not change protocol parity.

## Prioritized Backlog

### P0

#### Adopt QR v2 parsing and config modeling
Why it matters: iOS cannot join the gate/v2 lifecycle until it accepts the same pairing payload Android and the CLI already emit.
Scope
- Extend `ios/Handoff/Sources/Models/ConnectionConfig.swift` to carry protocol metadata used by v2.
- Update `ios/Handoff/Sources/Models/QRCodePayload.swift` to parse QR `v=2` compact fields.
- Preserve QR `v=1` parsing only as a compatibility path if needed during transition.
- Store nonce and protocol version in config persistence so verification and gate flows can reuse them.
References
- `android/app/src/main/java/com/handoff/app/data/ConnectionConfig.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/ScanScreen.kt`
- `bin/handoff` `cmd_pair`
Acceptance criteria
- iOS accepts the current QR payload emitted by `handoff pair`.
- Parsed config includes protocol version and nonce for v2 payloads.
- A v2-paired device can continue into auth/verification flow without manual edits.
Estimated branch name: `ios-v2-qr-config`
Depends on: none

#### Replace raw tmux discovery and actions with gate commands
Why it matters: raw tmux commands bypass the permission envelope that the Mac gate enforces for Android and the CLI.
Scope
- Change iOS session listing from raw `tmux list-sessions` to `list`.
- Change window listing from raw `tmux list-windows` to `windows <session>`.
- Change session/window mutations from raw tmux calls to `create-session`, `create-window`, `kill-session`, and `kill-window`.
- Add a gate-aware command execution layer in `SSHManager` instead of embedding raw tmux strings throughout views.
References
- `android/app/src/main/java/com/handoff/app/data/SshManager.kt`
- `bin/handoff` `cmd_gate`
Acceptance criteria
- iOS no longer shells raw tmux for session discovery or create/kill operations in the v2 path.
- Session visibility matches gate filtering from the Mac.
- Attempts to mutate state on a read-only device fail through gate errors, not raw tmux behavior.
Estimated branch name: `ios-v2-pairing-gate`
Depends on: `Adopt QR v2 parsing and config modeling`

#### Implement the pending-device verification handshake
Why it matters: without the `pair` handshake and six-digit verification step, iOS cannot complete the v2 device lifecycle.
Scope
- Add a verification screen in iOS matching the Android flow.
- After Tailscale auth, attempt `list` first.
- If gate returns `error:pending`, send `pair <device-name>`.
- Display the returned `verify:<code>` value.
- Poll until the device becomes active or pairing is rejected/times out.
References
- `android/app/src/main/java/com/handoff/app/ui/screens/VerificationScreen.kt`
- `android/app/src/main/java/com/handoff/app/data/SshManager.kt`
- `bin/handoff` `cmd_gate pair`
- `bin/handoff` `cmd_pair`
- `lib/handoff-common.sh` `derive_verification_code`
Acceptance criteria
- A freshly paired iOS device can complete the same six-digit verification flow as Android.
- If the Mac rejects pairing, iOS exits the flow cleanly and clears invalid local state.
- If the device is already active, iOS skips the pairing UI and proceeds directly after `list` succeeds.
Estimated branch name: `ios-v2-pairing-gate`
Depends on
- `Adopt QR v2 parsing and config modeling`
- `Replace raw tmux discovery and actions with gate commands`

#### Parse gate permissions and surface gate-specific errors
Why it matters: iOS must understand read-only mode, allowed-session filtering, and gate lifecycle errors instead of behaving like an unrestricted SSH client.
Scope
- Parse the `#permissions:` header returned by `list`.
- Add an iOS permissions model equivalent to Android's `DevicePermissions`.
- Surface read-only state in the sessions and terminal UI.
- Map gate errors such as `error:pending`, `error:soft_expired`, `error:not_found`, `error:read_only`, and `error:unknown_command` to user-facing messages.
- Disable create/kill affordances when the gate marks the device read-only.
References
- `android/app/src/main/java/com/handoff/app/data/SshManager.kt`
- `android/app/src/main/java/com/handoff/app/data/ErrorMessages.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/SessionsScreen.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/TerminalScreen.kt`
- `bin/handoff` `cmd_gate`
Acceptance criteria
- A read-only paired device shows a read-only indicator on iOS.
- Session/window mutation controls are absent or disabled in read-only mode.
- Gate lifecycle errors render specific recovery text instead of generic SSH failures.
Estimated branch name: `ios-readonly-errors`
Depends on: `Replace raw tmux discovery and actions with gate commands`

#### Route terminal attach through the gate
Why it matters: using raw `tmux attach` leaves the terminal path outside the same permission checks that protect discovery and mutation calls.
Scope
- Change `TerminalChannel.swift` to execute `attach <session> <window>` in the v2 path.
- Preserve raw tmux attach only as a compatibility fallback if v1 support is intentionally kept.
- Ensure read-only attach semantics come from the gate, not client-side convention.
References
- `android/app/src/main/java/com/handoff/app/data/SshManager.kt` `openShell`
- `bin/handoff` `cmd_gate attach`
- `ios/Handoff/Sources/Services/TerminalChannel.swift`
Acceptance criteria
- Interactive terminal attach in iOS uses the gate command in the v2 path.
- A read-only device attaches read-only because the gate enforces it.
- Session-scope restrictions apply equally to terminal attach and session listing.
Estimated branch name: `ios-v2-pairing-gate`
Depends on: `Replace raw tmux discovery and actions with gate commands`

### P1

#### Add an iOS settings and acknowledgements surface
Why it matters: public release requires a stable place for app security controls, acknowledgements, and account-reset actions.
Scope
- Add a settings screen reachable from sessions.
- Add an acknowledgements or licenses screen.
- Include Tailscale/account reset and host-key reset entry points.
- Keep scope to controls already analyzed; do not invent device-management features here.
References
- `android/app/src/main/java/com/handoff/app/ui/screens/SettingsScreen.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/LicensesScreen.kt`
- `android/app/src/main/java/com/handoff/app/MainActivity.kt`
Acceptance criteria
- iOS has a settings entry point from the main sessions UI.
- Licenses or acknowledgements are visible in-app.
- Security and reset actions no longer depend on ad hoc menu items alone.
Estimated branch name: `ios-settings-security`
Depends on: `Parse gate permissions and surface gate-specific errors`

#### Add a biometric app lock on iOS
Why it matters: Android already gates entry behind a biometric/PIN app lock path; iOS needs the same release-facing control.
Scope
- Add a biometric-gate screen before entering the authenticated app flow when enabled.
- Add a settings toggle for enabling/disabling the app lock.
- Match Android's scope: app entry gate, not SSH-key cryptographic binding.
References
- `android/app/src/main/java/com/handoff/app/ui/screens/BiometricGateScreen.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/SettingsScreen.kt`
- `android/app/src/main/java/com/handoff/app/MainActivity.kt`
Acceptance criteria
- When biometric app lock is enabled, reopening the app requires biometric or device credential before continuing.
- The user can disable the app lock from settings.
- The implementation is documented as an app lock, not as hardware-bound SSH key protection.
Estimated branch name: `ios-settings-security`
Depends on: `Add an iOS settings and acknowledgements surface`

#### Merge and harden host-key TOFU
Why it matters: host-key verification is the correct release-security bar even though Android has not caught up yet.
Scope
- Merge the TOFU implementation from the local `ios-host-key-verification` branch after review.
- Keep reset-trust entry points coherent with the final settings/security surface.
- Preserve the attempt-scoped pending-trust behavior and dedicated mismatch screen.
References
- `ios/Handoff/Sources/Services/HostKeyValidation.swift` on `ios-host-key-verification`
- `ios/Handoff/Sources/Services/HostKeyStore.swift` on `ios-host-key-verification`
- `ios/Handoff/Sources/Views/HostKeyTrustPromptView.swift` on `ios-host-key-verification`
- `ios/Handoff/Sources/Views/HostKeyMismatchView.swift` on `ios-host-key-verification`
Acceptance criteria
- First trust shows the host fingerprint and stores trust on approval.
- Mismatch blocks the connection and requires explicit reset before retry.
- Unpair clears stored host-key trust.
Estimated branch name: `ios-host-key-verification`
Depends on: none

#### Add expired-access and renewal-request UX
Why it matters: once iOS talks to gate, it must give users a path forward when the Mac reports soft expiry.
Scope
- Handle `error:soft_expired` with explicit UI instead of a generic failure state.
- Add a renewal-request action in the iOS client if the existing gate protocol is being used.
- Keep scope aligned with the current Mac gate behavior.
References
- `bin/handoff` `cmd_gate renew`
- `bin/handoff` `cmd_devices_renew`
- `android/app/src/main/java/com/handoff/app/data/SshManager.kt` `requestRenewal`
- `android/app/src/main/java/com/handoff/app/data/ErrorMessages.kt`
Acceptance criteria
- Soft-expired access does not dead-end in a generic error screen.
- If renewal is supported in the chosen iOS flow, the client can send `renew` and report the result.
- Users receive clear guidance when re-pairing is required instead of renewal.
Estimated branch name: `ios-expiry-renewal`
Depends on: `Parse gate permissions and surface gate-specific errors`

#### Tighten sessions-level reconnect behavior
Why it matters: Android's sessions screen is currently more aggressive about recovering stale tunnel and SSH state than iOS.
Scope
- Harden `SessionsView.swift` reconnect behavior after backgrounding or stale proxy state.
- Reuse the current iOS `TailscaleManager` state machine rather than rewriting networking.
- Align sessions-level recovery with the more robust reconnect expectations already present in `TerminalView.swift`.
References
- `android/app/src/main/java/com/handoff/app/ui/screens/SessionsScreen.kt`
- `android/app/src/main/java/com/handoff/app/data/TailscaleManager.kt`
- `ios/Handoff/Sources/Services/TailscaleManager.swift`
- `ios/Handoff/Sources/Views/SessionsView.swift`
- `ios/Handoff/Sources/Views/TerminalView.swift`
Acceptance criteria
- Returning to the sessions screen after stale tunnel/SSH state triggers a deterministic reconnect path.
- Users are not stranded on generic connection errors when a clean Tailscale restart would recover the session.
- Networking behavior remains compatible with embedded TailscaleKit and SOCKS5 auth.
Estimated branch name: `ios-reconnect-hardening`
Depends on: `Replace raw tmux discovery and actions with gate commands`

### P2

#### Surface device permissions and expiry metadata in iOS UI
Why it matters: once iOS consumes the gate permission model, it should also explain that model to the user.
Scope
- Show session scope and read-only state more explicitly in the client.
- Surface expiry metadata if it is available from analyzed flows.
- Keep this as informational UI only.
References
- `android/app/src/main/java/com/handoff/app/data/ConnectionConfig.kt`
- `android/app/src/main/java/com/handoff/app/data/SshManager.kt`
- `bin/handoff` `cmd_gate`
Acceptance criteria
- Users can tell whether the device is read-only and what session scope applies.
- UI does not invent permission states that are not backed by gate data.
Estimated branch name: `ios-permissions-metadata`
Depends on: `Parse gate permissions and surface gate-specific errors`

#### Normalize unpair semantics across platforms
Why it matters: Android and iOS currently make different choices about whether unpair also resets Tailscale auth.
Scope
- Decide whether iOS unpair should preserve or reset Tailscale auth.
- Document the chosen behavior.
- Align copy and code paths with that decision.
References
- `android/app/src/main/java/com/handoff/app/MainActivity.kt`
- `ios/Handoff/Sources/Views/SessionsView.swift`
- `ios/Handoff/Sources/Services/ConfigStore.swift`
Acceptance criteria
- iOS unpair behavior is explicit and documented.
- The user-facing copy matches what the code actually does.
Estimated branch name: `ios-unpair-alignment`
Depends on: none

#### Align platform copy and state naming after functional parity lands
Why it matters: copy cleanup is low value until the actual lifecycle and permission model match.
Scope
- Align verification wording, read-only messaging, and security-screen labels with the final iOS flows.
- Keep wording changes subordinate to functional parity work.
References
- `android/app/src/main/java/com/handoff/app/ui/screens/VerificationScreen.kt`
- `android/app/src/main/java/com/handoff/app/ui/screens/SessionsScreen.kt`
- `ios/Handoff/Sources/Views/*`
Acceptance criteria
- User-facing state names are consistent across the shipped iOS screens.
- Copy changes do not mask unresolved protocol or permission gaps.
Estimated branch name: `ios-copy-alignment`
Depends on
- `Add an iOS settings and acknowledgements surface`
- `Add a biometric app lock on iOS`
- `Merge and harden host-key TOFU`

## Non-goals / Deferred
- Do not treat hardware-bound SSH key protection as a parity requirement. Android main does not ship that today; its biometric layer is a UI gate.
- Do not treat host-key TOFU as Android catch-up work. It moves iOS ahead of Android's current `StrictHostKeyChecking=no` behavior.
- Do not build an in-app access-log feature just to chase parity. The Mac CLI has `handoff devices log`, but neither mobile client currently surfaces access logs in-app.
- Do not rewrite iOS networking just because Android and iOS embed Tailscale differently. iOS already has a stronger Tailscale state machine; the parity blocker is gate/v2 adoption, not tunnel architecture.
- Do not add new device-management capabilities beyond what was already analyzed. Anything beyond this roadmap is `TBD — not yet analyzed`.

## Corrections To Prior Assumptions
- Android main still connects with `StrictHostKeyChecking=no` in `android/app/src/main/java/com/handoff/app/data/SshManager.kt`.
- Android's biometric implementation is an app-entry UI gate, not hardware-bound SSH key protection. See `android/app/src/main/java/com/handoff/app/data/BiometricKeyStore.kt`.
- There is no in-app access-log surface on Android main.
- Android has a protocol hook for renewal requests, but a polished in-app renewal UX was not found in the analyzed Android UI paths.

## Suggested Branch Sequence
- `ios-v2-pairing-gate`
  - First move iOS onto QR v2, gate commands, verification, and gate-based attach so the client participates in the same permission and device lifecycle model as Android and the CLI.
- `ios-readonly-errors`
  - Next make the new gate path legible by parsing permissions, honoring read-only mode, and turning gate failures into specific recovery UI.
- `ios-settings-security`
  - Then add the release-facing security and settings surfaces: biometric app lock, acknowledgements, reset entry points, and the final home for TOFU controls.
