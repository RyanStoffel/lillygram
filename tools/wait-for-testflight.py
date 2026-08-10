#!/usr/bin/env python3
"""Wait until App Store Connect accepts a build and exposes it to a beta group."""

import argparse
import json
import time
import urllib.error
import urllib.request

import jwt

BASE_URL = "https://api.appstoreconnect.apple.com/v1"
TERMINAL_FAILURE_STATES = {"FAILED", "INVALID"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--group-id", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--interval", type=int, default=20)
    return parser.parse_args()


def authorization_token(args: argparse.Namespace) -> str:
    with open(args.key_path, encoding="utf-8") as key_file:
        private_key = key_file.read()
    now = int(time.time())
    return jwt.encode(
        {
            "iss": args.issuer_id,
            "iat": now,
            "exp": now + 19 * 60,
            "aud": "appstoreconnect-v1",
        },
        private_key,
        algorithm="ES256",
        headers={"kid": args.key_id, "typ": "JWT"},
    )


def get(path: str, args: argparse.Namespace) -> dict:
    request = urllib.request.Request(
        f"{BASE_URL}{path}",
        headers={"Authorization": f"Bearer {authorization_token(args)}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"App Store Connect returned HTTP {error.code}: {detail}") from error


def group_has_build(group_id: str, build_id: str, args: argparse.Namespace) -> bool:
    payload = get(f"/betaGroups/{group_id}/builds?limit=200", args)
    return any(build["id"] == build_id for build in payload.get("data", []))


def main() -> None:
    args = parse_args()
    deadline = time.monotonic() + args.timeout
    last_status = None

    while time.monotonic() < deadline:
        payload = get(f"/apps/{args.app_id}/builds?limit=50", args)
        build = next(
            (
                candidate
                for candidate in payload.get("data", [])
                if candidate["attributes"].get("version") == args.build_number
            ),
            None,
        )
        if build is None:
            status = "not visible"
        else:
            state = build["attributes"].get("processingState", "UNKNOWN")
            status = state
            if state in TERMINAL_FAILURE_STATES:
                raise SystemExit(f"TestFlight rejected build {args.build_number}: {state}")
            if state == "VALID" and group_has_build(args.group_id, build["id"], args):
                print(
                    f"TestFlight build {args.build_number} is VALID and available to the internal group",
                    flush=True,
                )
                return
            if state == "VALID":
                status = "VALID; waiting for internal-group availability"

        if status != last_status:
            print(f"TestFlight build {args.build_number}: {status}", flush=True)
            last_status = status
        time.sleep(args.interval)

    raise SystemExit(f"Timed out waiting for TestFlight build {args.build_number}")


if __name__ == "__main__":
    main()
