# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Handoff, please report it via [GitHub's private vulnerability reporting](https://github.com/SagiMedina/handoff/security/advisories/new).

## Scope

Handoff enables SSH access to your Mac over an encrypted Tailscale tunnel. Security-relevant areas include:

- SSH key generation, storage, and transmission (QR pairing)
- The `handoff gate` forced command (server-side access control)
- Device registration and permission enforcement
- Android-side key storage and biometric lock
- Tailscale/tsnet integration

## User Responsibility

- Keep your Tailscale account secure (enable 2FA)
- Review paired devices regularly (`handoff devices`)
- Revoke devices you no longer use (`handoff devices rm`)
- Enable biometric lock on the Android app for additional protection
