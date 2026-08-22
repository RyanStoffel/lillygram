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

## 4. DM sending is deliberately minimal

**Status:** implemented in 0.8.0 with narrow limits.

Threads and messages render natively and a single message can be sent per explicit
tap. Sending is metered as a write, so the per-account hourly cap and the
new-account warm-up both apply. There is no auto-reply, scheduled send, batching,
or mass messaging, and a failed send never retries automatically. DM writes remain
the least mature surface in unofficial API libraries, so keep volume low.

## 5. Live Instagram response validation remains required

**Status:** backend contracts and installed-library signatures verified; live
account traffic not exercised in this environment.

Tests cover session encryption, stable identity reuse, account-local challenge
freezing, hard limits, warm-up, missing DM writes, pagination mapping, and Reel
filtering. A designated account still must confirm current timeline, Story tray,
profile-media, DM, and upload response shapes before broader use.

## 6. Two-factor requires a stored authenticator seed

**Status:** resolved for authenticator accounts; other challenges stay manual.

Accounts with 2FA enabled cannot authenticate from username and password alone,
in any client library. Lillygram's supported path is Instagram's authenticator
setup key, saved once and used to derive codes locally.

Two mechanisms were tried and removed in 0.7.0:

- **SMS.** Selecting SMS in the Bloks challenge never produced a message for the
  test account. `should_fallback_to_sms` only marks SMS as available; it does not
  send one.
- **Device approval.** Approving in the official app authorizes that one pending
  challenge. A fresh password login creates a new unapproved challenge, so the
  completion check returned `TwoFactorRequired` every time.

Manual code entry remains for backup codes. Other challenge types still freeze
the account and direct the user to Instagram; there are no automatic loops.
Codes and the seed are masked in the native form. Treat any code or seed shown in
a screenshot, log, or chat as compromised and regenerate it.

## 7. TestFlight review/distribution risk

**Status:** monitor each release.

The app is fully native but depends on an unofficial Instagram backend. App Store
or Beta App Review may reject this architecture even for private testing. A
successful build and upload do not imply policy approval.
