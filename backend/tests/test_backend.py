from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

import pytest
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient

from lillygram_backend.config import Settings
from lillygram_backend.instagram import (
    InstagrapiClient,
    InstagramChallenge,
    InstagramRejected,
    InstagramVerificationRequired,
)
from lillygram_backend.main import create_app
from lillygram_backend.models import (
    DirectMessage,
    DirectThread,
    LoginRequest,
    Media,
    MediaKind,
    Profile,
    ProfileSummary,
    StoryTray,
)
from lillygram_backend.service import (
    AccountService,
    AccountUnavailable,
    RateLimitExceeded,
    WarmupRequired,
    _verification_message,
)
from lillygram_backend.storage import AccountStorage


class FakeInstagramClient:
    def __init__(
        self,
        settings: dict[str, Any],
        challenge_users: set[str],
        sms_requests: list[tuple[str, str]],
        sms_verifications: list[tuple[str, dict[str, Any], str]],
    ) -> None:
        self._settings = dict(settings)
        self._challenge_users = challenge_users
        self._sms_requests = sms_requests
        self._sms_verifications = sms_verifications

    def settings(self) -> dict[str, Any]:
        return dict(self._settings)

    def login(self, username: str, password: str, verification_code: str | None) -> None:
        if password != "correct horse":
            raise InstagramRejected("bad password")
        self._settings["username"] = username
        self._settings["authorization_data"] = {"sessionid": f"session-{username}"}

    def request_sms(self, username: str, password: str):
        if password != "correct horse":
            raise InstagramRejected("bad password")
        self._sms_requests.append((username, password))
        self._settings["username"] = username
        return {"kind": "bloks", "context": "secret-sms-context"}

    def verify_sms(self, username: str, context: dict[str, Any], code: str):
        self._sms_verifications.append((username, context, code))
        if code != "123456":
            raise InstagramRejected("bad SMS code")
        self._settings["authorization_data"] = {
            "sessionid": f"session-{username}"
        }

    def timeline(self, cursor: str | None):
        username = self._settings.get("username", "unknown")
        if username in self._challenge_users:
            raise InstagramChallenge("checkpoint_required")
        return [sample_media(username)], "next" if cursor is None else None

    def stories(self):
        return [StoryTray(user=sample_profile("friend"), items=[sample_media("friend")])]

    def search_accounts(self, query: str, amount: int):
        return [sample_profile(query)]

    def profile(self, username: str):
        return Profile(**sample_profile(username).model_dump())

    def profile_media(self, username: str, cursor: str | None, amount: int):
        return [sample_media(username)], None

    def direct_threads(self, amount: int):
        return [DirectThread(id="thread-1", title="Friend")]

    def direct_messages(self, thread_id: str, amount: int):
        return [DirectMessage(id="message-1", sender_id="friend", text="hello")]

    def media(self, media_id: str, shared_reel: bool = False):
        return sample_media("friend", reel=shared_reel)

    def upload_post(self, path: Path, caption: str, is_video: bool):
        return sample_media(self._settings["username"])

    def upload_story(self, path: Path, is_video: bool):
        return sample_media(self._settings["username"])


class FakeInstagramFactory:
    def __init__(self) -> None:
        self.generated_devices = 0
        self.challenge_users: set[str] = set()
        self.sms_requests: list[tuple[str, str]] = []
        self.sms_verifications: list[tuple[str, dict[str, Any], str]] = []

    def new(self, settings=None, proxy_url=None):
        if settings is None:
            self.generated_devices += 1
            settings = {"device_id": f"device-{self.generated_devices}", "uuids": {}}
        result = FakeInstagramClient(
            settings,
            self.challenge_users,
            self.sms_requests,
            self.sms_verifications,
        )
        if proxy_url:
            result._settings["proxy"] = proxy_url
        return result


def sample_profile(username: str) -> ProfileSummary:
    return ProfileSummary(username=username, full_name=username.title())


def sample_media(username: str, reel: bool = False) -> Media:
    return Media(
        id=f"media-{username}",
        kind=MediaKind.REEL if reel else MediaKind.PHOTO,
        user=sample_profile(username),
        shared_reel=reel,
    )


@pytest.fixture
def backend(tmp_path):
    key = Fernet.generate_key().decode()
    settings = Settings(
        database_path=tmp_path / "backend.sqlite3",
        encryption_key=key,
        allowed_origins=(),
        read_limit_per_hour=10,
        write_limit_per_hour=2,
        warmup_days=0,
        read_delay_seconds=(0, 0),
        write_delay_seconds=(0, 0),
    )
    storage = AccountStorage(settings.database_path, key, settings.warmup_days)
    factory = FakeInstagramFactory()

    async def no_sleep(_: float) -> None:
        return None

    service = AccountService(
        settings,
        storage,
        factory,
        sleep=no_sleep,
        random_uniform=lambda lower, upper: lower,
    )
    yield settings, storage, factory, service
    storage.close()


@pytest.mark.asyncio
async def test_login_reuses_one_stable_device_identity(backend):
    _, storage, factory, service = backend

    first = await service.login(
        LoginRequest(username="alice", password="correct horse", proxy_url="socks5://user:secret@proxy:1080")
    )
    first_record = storage.get_by_id(first.account.id)
    second = await service.login(LoginRequest(username="alice", password="correct horse"))
    second_record = storage.get_by_id(second.account.id)

    assert factory.generated_devices == 1
    assert first_record.settings["device_id"] == "device-1"
    assert second_record.settings["device_id"] == "device-1"
    assert first.token != second.token
    assert second.account.proxy_configured is True

    database = sqlite3.connect(storage._database_path)
    settings_blob, proxy_blob = database.execute(
        "SELECT settings_blob, proxy_blob FROM accounts WHERE id = ?", (first.account.id,)
    ).fetchone()
    assert b"device-1" not in settings_blob
    assert b"secret" not in proxy_blob


def test_storage_migrates_encrypted_sms_context_columns(tmp_path):
    database_path = tmp_path / "legacy.sqlite3"
    database = sqlite3.connect(database_path)
    database.execute(
        """
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY,
            username TEXT NOT NULL UNIQUE COLLATE NOCASE,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            settings_blob BLOB NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            proxy_blob BLOB,
            challenge_message TEXT
        )
        """
    )
    database.commit()
    database.close()

    storage = AccountStorage(database_path, Fernet.generate_key().decode(), 3)
    migrated = sqlite3.connect(database_path)
    columns = {
        row[1]
        for row in migrated.execute("PRAGMA table_info(accounts)").fetchall()
    }
    storage.close()
    migrated.close()

    assert {
        "verification_method",
        "verification_blob",
        "verification_expires_at",
    }.issubset(columns)


@pytest.mark.asyncio
async def test_challenge_freezes_only_the_affected_account(backend):
    _, storage, factory, service = backend
    alice = await service.login(LoginRequest(username="alice", password="correct horse"))
    bob = await service.login(LoginRequest(username="bob", password="correct horse"))
    factory.challenge_users.add("alice")

    alice_record = storage.get_by_id(alice.account.id)
    bob_record = storage.get_by_id(bob.account.id)
    with pytest.raises(AccountUnavailable):
        await service.timeline(alice_record, None)

    bob_page = await service.timeline(bob_record, None)
    assert bob_page.items[0].user.username == "bob"
    assert storage.get_by_id(alice.account.id).status.value == "challenge_required"
    assert storage.get_by_id(bob.account.id).status.value == "active"


@pytest.mark.asyncio
async def test_request_caps_are_hard_per_account(tmp_path):
    key = Fernet.generate_key().decode()
    settings = Settings(
        database_path=tmp_path / "limits.sqlite3",
        encryption_key=key,
        allowed_origins=(),
        read_limit_per_hour=1,
        write_limit_per_hour=1,
        warmup_days=0,
        read_delay_seconds=(0, 0),
        write_delay_seconds=(0, 0),
    )
    storage = AccountStorage(settings.database_path, key, 0)
    factory = FakeInstagramFactory()

    async def no_sleep(_: float) -> None:
        return None

    service = AccountService(settings, storage, factory, sleep=no_sleep)
    login = await service.login(LoginRequest(username="alice", password="correct horse"))
    account = storage.get_by_id(login.account.id)
    await service.timeline(account, None)
    with pytest.raises(RateLimitExceeded):
        await service.timeline(account, "next")
    storage.close()


@pytest.mark.asyncio
async def test_new_account_warmup_blocks_writes(tmp_path):
    key = Fernet.generate_key().decode()
    settings = Settings(
        database_path=tmp_path / "warmup.sqlite3",
        encryption_key=key,
        allowed_origins=(),
        warmup_days=3,
        read_delay_seconds=(0, 0),
        write_delay_seconds=(0, 0),
    )
    storage = AccountStorage(settings.database_path, key, 3)
    factory = FakeInstagramFactory()

    async def no_sleep(_: float) -> None:
        return None

    service = AccountService(settings, storage, factory, sleep=no_sleep)
    login = await service.login(LoginRequest(username="alice", password="correct horse"))
    account = storage.get_by_id(login.account.id)
    with pytest.raises(WarmupRequired):
        await service.upload_post(account, tmp_path / "photo.jpg", "caption", False)
    storage.close()


def test_api_requires_token_and_has_no_dm_send_route(backend):
    settings, storage, _, service = backend
    app = create_app(settings, storage=storage, service=service)
    with TestClient(app) as client:
        login = client.post(
            "/v1/auth/login",
            json={"username": "alice", "password": "correct horse"},
        )
        assert login.status_code == 200
        token = login.json()["token"]
        assert client.get("/v1/session").status_code == 401
        assert client.get(
            "/v1/session", headers={"Authorization": f"Bearer {token}"}
        ).json()["username"] == "alice"
        assert client.post(
            "/v1/direct/threads/thread-1/messages",
            headers={"Authorization": f"Bearer {token}"},
            json={"text": "bulk automation is intentionally unavailable"},
        ).status_code == 405


def test_failed_verification_never_echoes_or_mislabels_the_code(backend):
    settings, storage, _, service = backend
    app = create_app(settings, storage=storage, service=service)
    submitted_code = "00000000"

    with TestClient(app) as client:
        response = client.post(
            "/v1/auth/login",
            json={
                "username": "alice",
                "password": "incorrect",
                "verification_code": submitted_code,
            },
        )

    assert response.status_code == 401
    message = response.json()["error"]["message"]
    assert "rejected the sign-in" in message
    assert "unused backup code" in message
    assert submitted_code not in response.text


def test_sms_flow_is_one_shot_encrypted_and_passwordless_at_verification(backend):
    settings, storage, factory, service = backend
    app = create_app(settings, storage=storage, service=service)

    with TestClient(app) as client:
        login = client.post(
            "/v1/auth/login",
            json={"username": "alice", "password": "correct horse"},
        ).json()
        token = login["token"]
        account_id = login["account"]["id"]
        record = storage.get_by_id(account_id)
        storage.save_verification(
            account_id,
            record.settings,
            "sms",
            "SMS is available.",
        )
        headers = {"Authorization": f"Bearer {token}"}

        requested = client.post(
            "/v1/auth/request-sms",
            headers=headers,
            json={"password": "correct horse"},
        )
        database = sqlite3.connect(storage._database_path)
        pending_blob = database.execute(
            "SELECT verification_blob FROM accounts WHERE id = ?",
            (account_id,),
        ).fetchone()[0]
        assert b"secret-sms-context" not in pending_blob
        repeated = client.post(
            "/v1/auth/request-sms",
            headers=headers,
            json={"password": "correct horse"},
        )
        verified = client.post(
            "/v1/auth/verify-sms",
            headers=headers,
            json={"code": "123456"},
        )

    assert requested.status_code == 200
    assert requested.json()["verification_method"] == "sms"
    assert requested.json()["sms_pending"] is True
    assert repeated.status_code == 409
    assert verified.status_code == 200
    assert verified.json()["status"] == "active"
    assert verified.json()["sms_pending"] is False
    assert factory.sms_requests == [("alice", "correct horse")]
    assert factory.sms_verifications == [
        (
            "alice",
            {"kind": "bloks", "context": "secret-sms-context"},
            "123456",
        )
    ]

    verification_blob = database.execute(
        "SELECT verification_blob FROM accounts WHERE id = ?",
        (account_id,),
    ).fetchone()[0]
    assert verification_blob is None


def test_official_app_approval_can_complete_a_pending_sms_login(backend):
    settings, storage, _, service = backend
    app = create_app(settings, storage=storage, service=service)

    with TestClient(app) as client:
        login = client.post(
            "/v1/auth/login",
            json={"username": "alice", "password": "correct horse"},
        ).json()
        account_id = login["account"]["id"]
        record = storage.get_by_id(account_id)
        storage.save_verification(
            account_id,
            record.settings,
            "sms",
            "SMS is available.",
        )
        headers = {"Authorization": f"Bearer {login['token']}"}
        requested = client.post(
            "/v1/auth/request-sms",
            headers=headers,
            json={"password": "correct horse"},
        )
        approved = client.post(
            "/v1/auth/check-approval",
            headers=headers,
            json={"password": "correct horse"},
        )

    assert requested.status_code == 200
    assert requested.json()["sms_pending"] is True
    assert approved.status_code == 200
    assert approved.json()["status"] == "active"
    assert approved.json()["sms_pending"] is False


def test_instagrapi_boundary_paginates_and_filters_reels():
    class RawClient:
        search_count = None

        def get_timeline_feed(self, max_id=None):
            assert max_id == "cursor"
            return {
                "feed_items": [
                    {"media_or_ad": raw_media("photo")},
                    {"media_or_ad": raw_media("reel", product_type="clips")},
                ],
                "next_max_id": "next",
            }

        def get_reels_tray_feed(self):
            return {
                "tray": [
                    {
                        "user": {"username": "friend", "full_name": "Friend"},
                        "items": [raw_media("story")],
                    }
                ]
            }

        def search_users(self, query, count):
            self.search_count = count
            return [{"username": query, "full_name": "Result"}]

        def user_id_from_username(self, username):
            return "42"

        def user_medias_paginated_v1(self, user_id, amount, end_cursor):
            assert (user_id, amount, end_cursor) == ("42", 24, "profile-cursor")
            return [
                raw_media("profile-photo"),
                raw_media("profile-reel", product_type="clips"),
            ], "profile-next"

    raw = RawClient()
    client = object.__new__(InstagrapiClient)
    client._client = raw

    timeline, next_cursor = client.timeline("cursor")
    trays = client.stories()
    results = client.search_accounts("friend", 12)
    profile_media, profile_cursor = client.profile_media(
        "friend", "profile-cursor", 24
    )

    assert [item.id for item in timeline] == ["photo"]
    assert next_cursor == "next"
    assert trays[0].user.username == "friend"
    assert trays[0].items[0].id == "story"
    assert results[0].username == "friend"
    assert raw.search_count == 12
    assert [item.id for item in profile_media] == ["profile-photo"]
    assert profile_cursor == "profile-next"


@pytest.mark.parametrize(
    ("flag", "expected_method"),
    (("sms_two_factor_on", "sms"), ("totp_two_factor_on", "totp")),
)
def test_two_factor_method_is_classified_without_exposing_login_response(
    flag: str, expected_method: str
):
    two_factor_error = type("TwoFactorRequired", (Exception,), {})

    class RawClient:
        last_json = {"two_factor_info": {flag: True}}

        def login(self, username, password, verification_code):
            raise two_factor_error("two-factor required")

    client = object.__new__(InstagrapiClient)
    client._client = RawClient()

    with pytest.raises(InstagramVerificationRequired) as raised:
        client.login("account", "password", None)

    assert raised.value.method == expected_method


def test_instagrapi_sms_boundary_selects_and_verifies_one_context():
    two_factor_error = type("TwoFactorRequired", (Exception,), {})

    class RawClient:
        last_json = {
            "two_factor_info": {"sms_two_factor_on": True},
            "two_step_verification_context": "bloks-context",
        }
        selected_methods: list[str] = []
        verified: list[tuple[str, str, str]] = []
        login_flow_calls = 0

        def login(self, username, password, verification_code):
            raise two_factor_error("two-factor required")

        def bloks_two_step_verification_entrypoint(
            self, context, should_fallback_to_sms
        ):
            assert context == "bloks-context"
            assert should_fallback_to_sms is True

        def bloks_two_step_verification_method_picker(
            self, context, should_fallback_to_sms
        ):
            assert context == "bloks-context"
            assert should_fallback_to_sms is True

        def bloks_two_step_verification_select_method(
            self, context, selected_method, should_fallback_to_sms
        ):
            assert context == "bloks-context"
            assert should_fallback_to_sms is True
            self.selected_methods.append(selected_method)

        def bloks_two_step_verification_verify_code(
            self, context, code, challenge, should_fallback_to_sms
        ):
            assert should_fallback_to_sms is True
            self.verified.append((context, code, challenge))
            return {"login": "response"}

        def bloks_apply_login_response(self, result):
            return result == {"login": "response"}

        def login_flow(self):
            self.login_flow_calls += 1

    raw = RawClient()
    client = object.__new__(InstagrapiClient)
    client._client = raw

    context = client.request_sms("account", "password")
    client.verify_sms("account", context, "123456")

    assert context == {"kind": "bloks", "context": "bloks-context"}
    assert raw.selected_methods == ["sms"]
    assert raw.verified == [("bloks-context", "123456", "sms")]
    assert raw.login_flow_calls == 1


def test_verification_copy_does_not_claim_totp_was_sent():
    message = _verification_message(
        InstagramVerificationRequired("required", method="totp")
    )

    assert "authenticator app" in message
    assert "will not send an SMS" in message


def raw_media(media_id: str, product_type: str = "feed") -> dict[str, Any]:
    return {
        "pk": media_id,
        "media_type": 1,
        "product_type": product_type,
        "user": {"username": "friend", "full_name": "Friend"},
        "image_versions2": {
            "candidates": [{"url": f"https://cdn.example/{media_id}.jpg"}]
        },
    }
