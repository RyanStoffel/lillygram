from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

import pytest
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient

from lillygram_backend.config import Settings
from lillygram_backend.instagram import InstagrapiClient, InstagramChallenge
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
)
from lillygram_backend.storage import AccountStorage


class FakeInstagramClient:
    def __init__(
        self,
        settings: dict[str, Any],
        challenge_users: set[str],
    ) -> None:
        self._settings = dict(settings)
        self._challenge_users = challenge_users

    def settings(self) -> dict[str, Any]:
        return dict(self._settings)

    def login(self, username: str, password: str, verification_code: str | None) -> None:
        if password != "correct horse":
            from lillygram_backend.instagram import InstagramRejected

            raise InstagramRejected("bad password")
        self._settings["username"] = username
        self._settings["authorization_data"] = {"sessionid": f"session-{username}"}

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

    def new(self, settings=None, proxy_url=None):
        if settings is None:
            self.generated_devices += 1
            settings = {"device_id": f"device-{self.generated_devices}", "uuids": {}}
        result = FakeInstagramClient(settings, self.challenge_users)
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
