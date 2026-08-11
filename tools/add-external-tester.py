#!/usr/bin/env python3
"""Add an email as an external TestFlight tester, creating the external beta
group first if it doesn't exist yet."""

import argparse
import json
import time
import urllib.error
import urllib.request

import jwt

BASE_URL = "https://api.appstoreconnect.apple.com/v1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--group-name", default="External Testers")
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


def request(method: str, path: str, args: argparse.Namespace, body: dict | None = None) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Authorization": f"Bearer {authorization_token(args)}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(f"{BASE_URL}{path}", data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"App Store Connect returned HTTP {error.code} for {method} {path}: {detail}") from error


def find_external_group(args: argparse.Namespace) -> str | None:
    payload = request("GET", f"/apps/{args.app_id}/betaGroups?limit=200", args)
    for group in payload.get("data", []):
        attrs = group["attributes"]
        if attrs.get("name") == args.group_name and attrs.get("isInternalGroup") is False:
            return group["id"]
    return None


def create_external_group(args: argparse.Namespace) -> str:
    body = {
        "data": {
            "type": "betaGroups",
            "attributes": {"name": args.group_name, "isInternalGroup": False},
            "relationships": {
                "app": {"data": {"type": "apps", "id": args.app_id}},
            },
        }
    }
    payload = request("POST", "/betaGroups", args, body)
    return payload["data"]["id"]


def add_tester(group_id: str, args: argparse.Namespace) -> None:
    body = {
        "data": {
            "type": "betaTesters",
            "attributes": {"email": args.email},
            "relationships": {
                "betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]},
            },
        }
    }
    request("POST", "/betaTesters", args, body)


def main() -> None:
    args = parse_args()
    group_id = find_external_group(args)
    if group_id is None:
        group_id = create_external_group(args)
        print(f"Created external beta group '{args.group_name}' ({group_id})")
    else:
        print(f"Using existing external beta group '{args.group_name}' ({group_id})")

    add_tester(group_id, args)
    print(f"Added {args.email} as an external tester in '{args.group_name}'")


if __name__ == "__main__":
    main()
