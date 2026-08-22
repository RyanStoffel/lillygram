from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Protocol

from .models import (
    DirectMessage,
    DirectThread,
    Media,
    MediaAsset,
    MediaKind,
    Profile,
    ProfileSummary,
    StoryTray,
)


class InstagramChallenge(RuntimeError):
    pass


class InstagramVerificationRequired(RuntimeError):
    def __init__(self, message: str, method: str = "unknown") -> None:
        super().__init__(message)
        self.method = method


class InstagramReauthenticationRequired(RuntimeError):
    pass


class InstagramRejected(RuntimeError):
    pass


class InstagramClient(Protocol):
    def settings(self) -> dict[str, Any]: ...
    def login(self, username: str, password: str, verification_code: str | None) -> None: ...
    def timeline(self, cursor: str | None) -> tuple[list[Media], str | None]: ...
    def stories(self) -> list[StoryTray]: ...
    def search_accounts(self, query: str, amount: int) -> list[ProfileSummary]: ...
    def profile(self, username: str) -> Profile: ...
    def profile_media(
        self, username: str, cursor: str | None, amount: int
    ) -> tuple[list[Media], str | None]: ...
    def direct_threads(self, amount: int) -> list[DirectThread]: ...
    def direct_messages(self, thread_id: str, amount: int) -> list[DirectMessage]: ...
    def media(self, media_id: str, shared_reel: bool = False) -> Media: ...
    def upload_post(self, path: Path, caption: str, is_video: bool) -> Media: ...
    def upload_story(self, path: Path, is_video: bool) -> Media: ...


class InstagramClientFactory(Protocol):
    def new(
        self, settings: dict[str, Any] | None = None, proxy_url: str | None = None
    ) -> InstagramClient: ...


class InstagrapiFactory:
    def new(
        self, settings: dict[str, Any] | None = None, proxy_url: str | None = None
    ) -> InstagramClient:
        return InstagrapiClient(settings=settings, proxy_url=proxy_url)


class InstagrapiClient:
    """Small typed boundary around instagrapi.

    A new wrapper and underlying Client are constructed for every operation.
    The caller serializes operations per account and persists settings afterward.
    """

    def __init__(
        self, settings: dict[str, Any] | None = None, proxy_url: str | None = None
    ) -> None:
        from instagrapi import Client

        self._client = Client()
        if settings:
            self._client.set_settings(settings)
        if proxy_url:
            self._client.set_proxy(proxy_url)

    def settings(self) -> dict[str, Any]:
        return self._client.get_settings()

    def login(
        self, username: str, password: str, verification_code: str | None
    ) -> None:
        try:
            logged_in = self._client.login(
                username,
                password,
                verification_code=verification_code or "",
            )
            if not logged_in:
                raise InstagramRejected("Instagram rejected the login")
        except Exception as error:
            self._raise_mapped(error)

    def timeline(self, cursor: str | None) -> tuple[list[Media], str | None]:
        try:
            payload = self._client.get_timeline_feed(max_id=cursor)
            items = _value(payload, "feed_items", []) or _value(payload, "items", []) or []
            medias: list[Media] = []
            for item in items:
                raw_media = _value(item, "media_or_ad") or _value(item, "media") or item
                if _is_reel(raw_media):
                    continue
                converted = _media(raw_media)
                if converted is not None and converted.kind != MediaKind.REEL:
                    medias.append(converted)
            next_cursor = _string(_value(payload, "next_max_id"))
            return medias, next_cursor
        except Exception as error:
            self._raise_mapped(error)

    def stories(self) -> list[StoryTray]:
        try:
            payload = self._client.get_reels_tray_feed()
            reels = _value(payload, "tray", []) or []
            trays: list[StoryTray] = []
            for reel in reels or []:
                user = _profile_summary(_value(reel, "user") or reel)
                items = [item for raw in (_value(reel, "items", []) or []) if (item := _media(raw))]
                if items:
                    trays.append(StoryTray(user=user, items=items))
            return trays
        except Exception as error:
            self._raise_mapped(error)

    def search_accounts(self, query: str, amount: int) -> list[ProfileSummary]:
        try:
            return [
                _profile_summary(user)
                for user in self._client.search_users(query, count=amount)
            ]
        except Exception as error:
            self._raise_mapped(error)

    def profile(self, username: str) -> Profile:
        try:
            user = self._client.user_info_by_username_v1(username)
            summary = _profile_summary(user)
            return Profile(
                **summary.model_dump(),
                biography=_string(_value(user, "biography")) or "",
                follower_count=_integer(_value(user, "follower_count")),
                following_count=_integer(_value(user, "following_count")),
                media_count=_integer(_value(user, "media_count")),
            )
        except Exception as error:
            self._raise_mapped(error)

    def profile_media(
        self, username: str, cursor: str | None, amount: int
    ) -> tuple[list[Media], str | None]:
        try:
            user_id = self._client.user_id_from_username(username)
            raw_items, next_cursor = self._client.user_medias_paginated_v1(
                user_id,
                amount=amount,
                end_cursor=cursor or "",
            )
            items = [
                converted
                for raw in raw_items
                if (converted := _media(raw)) is not None
                and converted.kind != MediaKind.REEL
            ]
            return items, next_cursor or None
        except Exception as error:
            self._raise_mapped(error)

    def direct_threads(self, amount: int) -> list[DirectThread]:
        try:
            return [_thread(thread) for thread in self._client.direct_threads(amount=amount)]
        except Exception as error:
            self._raise_mapped(error)

    def direct_messages(self, thread_id: str, amount: int) -> list[DirectMessage]:
        try:
            return [
                _message(message)
                for message in self._client.direct_messages(thread_id, amount=amount)
            ]
        except Exception as error:
            self._raise_mapped(error)

    def media(self, media_id: str, shared_reel: bool = False) -> Media:
        try:
            converted = _media(self._client.media_info(media_id), shared_reel=shared_reel)
            if converted is None:
                raise InstagramRejected("Instagram returned no media")
            return converted
        except Exception as error:
            self._raise_mapped(error)

    def upload_post(self, path: Path, caption: str, is_video: bool) -> Media:
        try:
            result = (
                self._client.video_upload(path, caption=caption)
                if is_video
                else self._client.photo_upload(path, caption=caption)
            )
            converted = _media(result)
            if converted is None:
                raise InstagramRejected("Instagram returned no uploaded post")
            return converted
        except Exception as error:
            self._raise_mapped(error)

    def upload_story(self, path: Path, is_video: bool) -> Media:
        try:
            result = (
                self._client.video_upload_to_story(path)
                if is_video
                else self._client.photo_upload_to_story(path)
            )
            converted = _media(result)
            if converted is None:
                raise InstagramRejected("Instagram returned no uploaded story")
            return converted
        except Exception as error:
            self._raise_mapped(error)

    def _raise_mapped(self, error: Exception) -> None:
        name = type(error).__name__
        message = str(error) or name
        if name in {
            "ChallengeRequired",
            "ChallengeUnknownStep",
            "ChallengeSelfieCaptcha",
            "PleaseWaitFewMinutes",
            "FeedbackRequired",
            "SentryBlock",
            "RateLimitError",
            "ProxyAddressIsBlocked",
        }:
            raise InstagramChallenge(message) from error
        if name == "TwoFactorRequired":
            raise InstagramVerificationRequired(
                message,
                method=self._verification_method(),
            ) from error
        if name == "ReloginAttemptExceeded":
            raise InstagramVerificationRequired(message) from error
        if name in {"LoginRequired", "ClientLoginRequired"}:
            raise InstagramReauthenticationRequired(message) from error
        if isinstance(error, (
            InstagramChallenge,
            InstagramVerificationRequired,
            InstagramReauthenticationRequired,
            InstagramRejected,
        )):
            raise error
        raise InstagramRejected(message) from error

    def _verification_method(self) -> str:
        login_response = getattr(self._client, "last_json", None)
        sms_enabled = _nested_bool(login_response, "sms_two_factor_on")
        totp_enabled = _nested_bool(login_response, "totp_two_factor_on")
        if totp_enabled:
            return "totp"
        if sms_enabled:
            return "sms"
        return "unknown"


def initial_device_settings(factory: InstagramClientFactory) -> dict[str, Any]:
    """Generate the per-account device identity exactly once, before login."""
    return factory.new().settings()


def _value(value: Any, key: str, default: Any = None) -> Any:
    if isinstance(value, dict):
        return value.get(key, default)
    return getattr(value, key, default)

def _nested_bool(value: Any, key: str) -> bool:
    if isinstance(value, dict):
        if key in value:
            candidate = value[key]
            if isinstance(candidate, bool):
                return candidate
            if isinstance(candidate, int):
                return candidate != 0
            if isinstance(candidate, str):
                return candidate.strip().lower() in {"1", "true", "yes"}
        return any(_nested_bool(child, key) for child in value.values())
    if isinstance(value, list):
        return any(_nested_bool(child, key) for child in value)
    return False


def _string(value: Any) -> str | None:
    if value is None:
        return None
    result = str(value)
    return result if result else None


def _integer(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _datetime(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=UTC)
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value / 1_000_000 if value > 10**12 else value, UTC)
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
        except ValueError:
            return None
    return None


def _url(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, (list, tuple)):
        return _url(value[0]) if value else None
    if isinstance(value, dict):
        return _url(value.get("url") or value.get("src"))
    candidate = _value(value, "url") or _value(value, "src") or value
    result = str(candidate)
    return result if result.startswith(("https://", "http://")) else None


def _profile_summary(user: Any) -> ProfileSummary:
    return ProfileSummary(
        username=_string(_value(user, "username")) or "unknown",
        full_name=_string(_value(user, "full_name")) or "",
        avatar_url=_url(
            _value(user, "profile_pic_url_hd") or _value(user, "profile_pic_url")
        ),
        is_verified=bool(_value(user, "is_verified", False)),
    )


def _is_reel(media: Any) -> bool:
    product_type = (_string(_value(media, "product_type")) or "").lower()
    media_type = (_string(_value(media, "media_type")) or "").lower()
    return product_type in {"clips", "reels", "reel"} or media_type == "reel"


def _media(media: Any, shared_reel: bool = False) -> Media | None:
    if media is None:
        return None
    raw_id = _value(media, "pk") or _value(media, "id")
    if raw_id is None:
        return None
    is_reel = _is_reel(media)
    media_type = _integer(_value(media, "media_type"))
    if is_reel:
        kind = MediaKind.REEL
    elif media_type == 2:
        kind = MediaKind.VIDEO
    elif media_type == 8:
        kind = MediaKind.CAROUSEL
    else:
        kind = MediaKind.PHOTO
    resources = _value(media, "resources", []) or _value(media, "carousel_media", []) or []
    carousel_items = [
        MediaAsset(
            kind=MediaKind.VIDEO if _integer(_value(item, "media_type")) == 2 else MediaKind.PHOTO,
            thumbnail_url=_url(
                _value(item, "thumbnail_url")
                or _value(_value(item, "image_versions2", {}), "candidates", [])
            ),
            media_url=_url(_value(item, "video_url") or _value(item, "video_versions")),
        )
        for item in resources
    ]
    caption_value = _value(media, "caption_text")
    if caption_value is None:
        caption = _value(media, "caption")
        caption_value = _value(caption, "text", "") if caption else ""
    thumbnail = _url(
        _value(media, "thumbnail_url")
        or _value(_value(media, "image_versions2", {}), "candidates", [])
    )
    video_url = _url(_value(media, "video_url") or _value(media, "video_versions"))
    return Media(
        id=str(raw_id),
        code=_string(_value(media, "code")),
        kind=kind,
        caption=_string(caption_value) or "",
        taken_at=_datetime(_value(media, "taken_at")),
        user=_profile_summary(_value(media, "user") or {}),
        thumbnail_url=thumbnail,
        media_url=video_url if kind in {MediaKind.VIDEO, MediaKind.REEL} else thumbnail,
        carousel_items=carousel_items,
        like_count=_integer(_value(media, "like_count")),
        comment_count=_integer(_value(media, "comment_count")),
        shared_reel=shared_reel and kind == MediaKind.REEL,
    )


def _message(message: Any) -> DirectMessage:
    raw_media = (
        _value(message, "clip")
        or _value(message, "reel_share")
        or _value(message, "media_share")
        or _value(message, "media")
    )
    shared_reel = _value(message, "clip") is not None or _value(message, "reel_share") is not None
    return DirectMessage(
        id=_string(_value(message, "id")) or "",
        sender_id=_string(_value(message, "user_id")) or "",
        text=_string(_value(message, "text")) or "",
        timestamp=_datetime(_value(message, "timestamp")),
        media=_media(raw_media, shared_reel=shared_reel),
    )


def _thread(thread: Any) -> DirectThread:
    return DirectThread(
        id=_string(_value(thread, "id")) or "",
        title=_string(_value(thread, "thread_title")) or "Conversation",
        users=[_profile_summary(user) for user in (_value(thread, "users", []) or [])],
        messages=[_message(message) for message in (_value(thread, "messages", []) or [])],
    )
