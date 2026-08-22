# Known Issues and Follow-ups

## 1. Unofficial API account risk

**Status:** inherent, not resolved.

`instagrapi` uses Instagram's private mobile API. Stable devices, encrypted
sessions, per-account isolation, pacing, hard limits, warm-up, and proxies reduce
avoidable risk but cannot guarantee that Meta will not challenge, restrict, or
ban an account. Use designated test accounts before family accounts.

## 2. Backend deployment is not part of this repository

**Status:** configuration implemented; hosting pending.

The backend ships as a Docker image and the iOS app accepts a configurable HTTPS
URL. No production host, domain, TLS certificate, database volume, backup policy,
or monitoring destination was supplied for this migration. Physical-device use
requires deploying the service and preserving both its database and encryption
key.

## 3. Per-user proxy provisioning is external

**Status:** supported but not automated.

Each account can store one encrypted stable proxy URL and every fresh client
reapplies it. Lillygram does not purchase, validate, rotate, or health-check
residential/mobile proxies. Automatic rotation would violate the stable-identity
model.

## 4. DMs are read-only

**Status:** intentional v0.5 safety boundary.

Threads and messages render natively. Replies hand off to Instagram. The backend
has no DM-send endpoint because unofficial DM writes are the highest-risk and
least mature requested surface. Revisit only with real-account evidence and a
narrow manual-send contract.

## 5. Live Instagram response validation remains required

**Status:** backend contracts and installed-library signatures verified; live
account traffic not exercised in this environment.

Tests cover session encryption, stable identity reuse, account-local challenge
freezing, hard limits, warm-up, missing DM writes, pagination mapping, and Reel
filtering. A designated account still must confirm current timeline, Story tray,
profile-media, DM, and upload response shapes before broader use.

## 6. Challenge resolution is deliberately manual

**Status:** by design.

Two-factor login accepts one user-entered authenticator, SMS, or backup code.
When Instagram explicitly advertises SMS, Lillygram can select that method once
and verify the resulting code against a minimal encrypted challenge context that
expires after ten minutes. It cannot retrieve a code, resend while one is
pending, or guarantee carrier delivery. Other challenges freeze that account
and direct the user to Instagram; there are no automatic challenge loops.
Verification and backup codes are masked in the native form and cleared after
every submission. Treat any code shown in a screenshot, log, or chat as
compromised and regenerate Instagram's backup-code set before retrying.

## 7. TestFlight review/distribution risk

**Status:** monitor each release.

The app is fully native but depends on an unofficial Instagram backend. App Store
or Beta App Review may reject this architecture even for private testing. A
successful build and upload do not imply policy approval.
