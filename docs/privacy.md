# Privacy Policy

**Handoff** — Last updated: April 14, 2026

## What Handoff Does

Handoff lets you continue Mac terminal sessions on your Android phone. It connects your phone to your Mac over a private Tailscale network using SSH.

## Data Collection

Handoff does **not** collect, transmit, or store any personal data on external servers. There are no analytics, tracking, or advertising SDKs.

### Data stored locally on your device

- **SSH private key** — Used to authenticate with your Mac. Stored in Android's encrypted storage (EncryptedSharedPreferences). Never transmitted to any third party.
- **Connection configuration** — Your Mac's Tailscale IP address, username, and tmux path. Stored locally in Android DataStore.

### Data transmitted to third parties

- **Tailscale authentication** — On first launch, Handoff authenticates with Tailscale's servers to establish a secure peer-to-peer connection. This uses Tailscale's embedded networking library (tsnet). Tailscale's own privacy policy applies to this authentication: [https://tailscale.com/privacy-policy](https://tailscale.com/privacy-policy)
- **SSH traffic** — Terminal data flows directly between your phone and your Mac over an encrypted WireGuard tunnel via Tailscale. No terminal content passes through any intermediary server.

### Camera

The camera is used **only** for scanning a QR code during initial pairing. No images are stored, transmitted, or processed beyond reading the QR code contents.

## Data Sharing

Handoff shares no data with third parties. All terminal traffic is peer-to-peer between your phone and your Mac.

## Data Deletion

Uninstalling the app removes all locally stored data. You can also unpair from within the app, which clears all stored credentials.

## Open Source

Handoff is open source. You can review the full source code at [https://github.com/SagiMedina/handoff](https://github.com/SagiMedina/handoff).

## Contact

For questions about this privacy policy, open an issue at [https://github.com/SagiMedina/handoff/issues](https://github.com/SagiMedina/handoff/issues).
