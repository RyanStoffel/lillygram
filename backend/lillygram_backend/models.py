from __future__ import annotations

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field


class AccountStatus(StrEnum):
    ACTIVE = "active"
    VERIFICATION_REQUIRED = "verification_required"
    CHALLENGE_REQUIRED = "challenge_required"
    REAUTH_REQUIRED = "reauth_required"


class Account(BaseModel):
    id: str
    username: str
    status: AccountStatus
    created_at: datetime
    writes_enabled_at: datetime
    challenge_message: str | None = None
    proxy_configured: bool = False
    verification_method: str | None = None
    totp_configured: bool = False


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)
    verification_code: str | None = Field(default=None, min_length=4, max_length=16)
    proxy_url: str | None = Field(default=None, max_length=512)


class LoginResponse(BaseModel):
    token: str
    account: Account

class TOTPSeedRequest(BaseModel):
    """Instagram's authenticator setup key, base32 as shown during 2FA setup.

    A null seed clears the stored key.
    """

    seed: str | None = Field(default=None, min_length=16, max_length=128)


class DirectMessageRequest(BaseModel):
    text: str = Field(min_length=1, max_length=1000)


class ProxySettings(BaseModel):
    proxy_url: str | None = Field(default=None, max_length=512)


class AppSettings(BaseModel):
    account: Account
    read_limit_per_hour: int
    write_limit_per_hour: int
    warmup_days: int


class ProfileSummary(BaseModel):
    username: str
    full_name: str = ""
    avatar_url: str | None = None
    is_verified: bool = False


class Profile(ProfileSummary):
    biography: str = ""
    follower_count: int = 0
    following_count: int = 0
    media_count: int = 0


class MediaKind(StrEnum):
    PHOTO = "photo"
    VIDEO = "video"
    CAROUSEL = "carousel"
    REEL = "reel"


class MediaAsset(BaseModel):
    kind: MediaKind
    thumbnail_url: str | None = None
    media_url: str | None = None


class Media(BaseModel):
    id: str
    code: str | None = None
    kind: MediaKind
    caption: str = ""
    taken_at: datetime | None = None
    user: ProfileSummary
    thumbnail_url: str | None = None
    media_url: str | None = None
    carousel_items: list[MediaAsset] = Field(default_factory=list)
    like_count: int = 0
    comment_count: int = 0
    shared_reel: bool = False


class StoryTray(BaseModel):
    user: ProfileSummary
    items: list[Media] = Field(default_factory=list)


class DirectMessage(BaseModel):
    id: str
    sender_id: str
    text: str = ""
    sent_by_viewer: bool = False
    timestamp: datetime | None = None
    media: Media | None = None


class DirectThread(BaseModel):
    id: str
    title: str
    users: list[ProfileSummary] = Field(default_factory=list)
    messages: list[DirectMessage] = Field(default_factory=list)


class Page(BaseModel):
    model_config = ConfigDict(arbitrary_types_allowed=True)

    items: list
    next_cursor: str | None = None


class UploadResponse(BaseModel):
    media: Media
