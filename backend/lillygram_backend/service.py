from __future__ import annotations

import asyncio
import logging
import random
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Awaitable, Callable, TypeVar

from .config import Settings
from .instagram import (
    InstagramChallenge,
    InstagramClient,
    InstagramClientFactory,
    InstagramError,
    InstagramReauthenticationRequired,
    InstagramRejected,
    InstagramVerificationRequired,
    initial_device_settings,
)
from .models import (
    Account,
    AccountStatus,
    AppSettings,
    DirectMessage,
    DirectThread,
    LoginRequest,
    LoginResponse,
    Media,
    Page,
    Profile,
    ProfileSummary,
    StoryTray,
)
from .storage import AccountRecord, AccountStorage

T = TypeVar("T")
_logger = logging.getLogger("lillygram.auth")


def _log_upstream(stage: str, error: InstagramError) -> None:
    """Record why Instagram refused, without touching secrets."""
    _logger.warning(
        "%s refused: upstream=%s reason=%s",
        stage,
        error.upstream or type(error).__name__,
        error.reason or "<none>",
    )



def _verification_message(error: InstagramVerificationRequired) -> str:
    base = (
        "Save your Instagram authenticator setup key in Settings so Lillygram "
        "can generate codes automatically."
    )
    if error.method == "totp":
        return f"Enter the current 6-digit authenticator code. {base}"
    if error.method == "sms":
        return (
            "Instagram wants an SMS code, but delivery is unreliable for this "
            f"account and Lillygram cannot resend it. {base}"
        )
    return (
        "Enter a current authenticator code or an unused backup code. "
        f"{base}"
    )


class ServiceError(RuntimeError):
    status_code = 500
    code = "service_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message

class BadRequest(ServiceError):
    status_code = 400
    code = "bad_request"


class Unauthorized(ServiceError):
    status_code = 401
    code = "unauthorized"


class AccountUnavailable(ServiceError):
    status_code = 409
    code = "account_unavailable"


class RateLimitExceeded(ServiceError):
    status_code = 429
    code = "rate_limit_exceeded"


class WarmupRequired(ServiceError):
    status_code = 403
    code = "warmup_required"


class UpstreamRejected(ServiceError):
    status_code = 502
    code = "instagram_rejected"


class AccountService:
    def __init__(
        self,
        settings: Settings,
        storage: AccountStorage,
        client_factory: InstagramClientFactory,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        random_uniform: Callable[[float, float], float] = random.uniform,
    ) -> None:
        self.settings = settings
        self.storage = storage
        self.client_factory = client_factory
        self._sleep = sleep
        self._random_uniform = random_uniform
        self._locks: dict[str, asyncio.Lock] = {}
        self._locks_guard = asyncio.Lock()

    async def login(self, request: LoginRequest) -> LoginResponse:
        username = request.username.strip()
        if not username:
            raise Unauthorized("Username is required")
        record, initial_token = await asyncio.to_thread(
            self.storage.get_or_create_account,
            username,
            lambda: initial_device_settings(self.client_factory),
            request.proxy_url,
        )
        lock = await self._lock_for(record.id)
        async with lock:
            record = await asyncio.to_thread(self.storage.get_by_id, record.id)
            await self._enforce_login_limit(record)
            await self._pace("write")
            client = self.client_factory.new(record.settings, record.proxy_url)
            # A stored authenticator seed makes two-factor deterministic: derive
            # the current code instead of waiting on SMS or device approval.
            verification_code = request.verification_code
            if not verification_code and record.totp_seed:
                verification_code = client.totp_code(record.totp_seed)
            try:
                await asyncio.to_thread(
                    client.login,
                    username,
                    request.password,
                    verification_code,
                )
            except InstagramVerificationRequired as error:
                _log_upstream("login", error)
                await asyncio.to_thread(
                    self.storage.save_verification,
                    record.id,
                    client.settings(),
                    error.method,
                    _verification_message(error),
                )
            except InstagramChallenge as error:
                _log_upstream("login", error)
                await asyncio.to_thread(
                    self.storage.save_session,
                    record.id,
                    client.settings(),
                    AccountStatus.CHALLENGE_REQUIRED,
                    "Instagram requires verification. Complete it in the official app, then reconnect Lillygram.",
                )
            except InstagramReauthenticationRequired as error:
                _log_upstream("login", error)
                await asyncio.to_thread(
                    self.storage.save_session,
                    record.id,
                    client.settings(),
                    AccountStatus.REAUTH_REQUIRED,
                    "Instagram rejected this session. Sign in again manually.",
                )
            except InstagramRejected as error:
                _log_upstream("login", error)
                if record.totp_seed and not request.verification_code:
                    raise Unauthorized(
                        "Instagram rejected the generated authenticator code. "
                        "Confirm the password and that the stored setup key "
                        "matches this account."
                    ) from error
                if verification_code:
                    raise Unauthorized(
                        "Instagram rejected the sign-in. Confirm the password and "
                        "use a fresh authenticator or unused backup code."
                    ) from error
                raise Unauthorized("Instagram rejected the credentials") from error
            else:
                await asyncio.to_thread(
                    self.storage.save_session,
                    record.id,
                    client.settings(),
                    AccountStatus.ACTIVE,
                    None,
                )
            token = initial_token or await asyncio.to_thread(
                self.storage.rotate_token, record.id
            )
            updated = await asyncio.to_thread(self.storage.get_by_id, record.id)
            return LoginResponse(token=token, account=self.storage.account_model(updated))

    async def authenticate(self, token: str) -> AccountRecord:
        record = await asyncio.to_thread(self.storage.get_by_token, token)
        if record is None:
            raise Unauthorized("Invalid session token")
        return record

    async def session(self, record: AccountRecord):
        current = await asyncio.to_thread(self.storage.get_by_id, record.id)
        return self.storage.account_model(current)

    async def set_totp_seed(
        self, record: AccountRecord, seed: str | None
    ) -> Account:
        """Store or clear the authenticator seed used to derive login codes."""
        if seed is not None:
            # Fail before persisting rather than at the next login attempt.
            try:
                self.client_factory.new().totp_code(seed)
            except InstagramRejected as error:
                raise BadRequest(
                    "That is not a valid Instagram authenticator setup key"
                ) from error
        await asyncio.to_thread(self.storage.save_totp_seed, record.id, seed)
        updated = await asyncio.to_thread(self.storage.get_by_id, record.id)
        return self.storage.account_model(updated)

    async def app_settings(self, record: AccountRecord) -> AppSettings:
        current = await asyncio.to_thread(self.storage.get_by_id, record.id)
        return AppSettings(
            account=self.storage.account_model(current),
            read_limit_per_hour=self.settings.read_limit_per_hour,
            write_limit_per_hour=self.settings.write_limit_per_hour,
            warmup_days=self.settings.warmup_days,
        )

    async def set_proxy(self, record: AccountRecord, proxy_url: str | None) -> AppSettings:
        await asyncio.to_thread(self.storage.set_proxy, record.id, proxy_url)
        return await self.app_settings(record)

    async def timeline(
        self, record: AccountRecord, cursor: str | None
    ) -> Page:
        items, next_cursor = await self._operate(
            record, "read", lambda client: client.timeline(cursor)
        )
        return Page(items=items, next_cursor=next_cursor)

    async def stories(self, record: AccountRecord) -> list[StoryTray]:
        return await self._operate(record, "read", lambda client: client.stories())

    async def search_accounts(
        self, record: AccountRecord, query: str, amount: int
    ) -> list[ProfileSummary]:
        return await self._operate(
            record, "read", lambda client: client.search_accounts(query, amount)
        )

    async def profile(self, record: AccountRecord, username: str) -> Profile:
        return await self._operate(
            record, "read", lambda client: client.profile(username)
        )

    async def profile_media(
        self,
        record: AccountRecord,
        username: str,
        cursor: str | None,
        amount: int,
    ) -> Page:
        items, next_cursor = await self._operate(
            record,
            "read",
            lambda client: client.profile_media(username, cursor, amount),
        )
        return Page(items=items, next_cursor=next_cursor)

    async def direct_threads(
        self, record: AccountRecord, amount: int
    ) -> list[DirectThread]:
        return await self._operate(
            record, "read", lambda client: client.direct_threads(amount)
        )

    async def direct_messages(
        self, record: AccountRecord, thread_id: str, amount: int
    ) -> list[DirectMessage]:
        return await self._operate(
            record,
            "read",
            lambda client: client.direct_messages(thread_id, amount),
        )

    async def send_direct_message(
        self, record: AccountRecord, thread_id: str, text: str
    ) -> DirectMessage:
        """Sending counts as a write: warm-up and hourly caps both apply."""
        return await self._operate(
            record,
            "write",
            lambda client: client.send_direct_message(thread_id, text),
        )

    async def media(
        self, record: AccountRecord, media_id: str, shared_reel: bool
    ) -> Media:
        return await self._operate(
            record,
            "read",
            lambda client: client.media(media_id, shared_reel=shared_reel),
        )

    async def upload_post(
        self,
        record: AccountRecord,
        path: Path,
        caption: str,
        is_video: bool,
    ) -> Media:
        return await self._operate(
            record,
            "write",
            lambda client: client.upload_post(path, caption, is_video),
        )

    async def upload_story(
        self, record: AccountRecord, path: Path, is_video: bool
    ) -> Media:
        return await self._operate(
            record,
            "write",
            lambda client: client.upload_story(path, is_video),
        )

    async def _operate(
        self,
        record: AccountRecord,
        category: str,
        operation: Callable[[InstagramClient], T],
    ) -> T:
        lock = await self._lock_for(record.id)
        async with lock:
            current = await asyncio.to_thread(self.storage.get_by_id, record.id)
            self._ensure_available(current)
            await self._enforce_limit(current, category)
            await self._pace(category)
            client = self.client_factory.new(current.settings, current.proxy_url)
            try:
                result = await asyncio.to_thread(operation, client)
            except InstagramChallenge as error:
                await self._freeze(
                    current,
                    AccountStatus.CHALLENGE_REQUIRED,
                    "Instagram requires verification. Complete it in the official app; Lillygram will not retry automatically.",
                    client,
                )
                raise AccountUnavailable("Instagram verification is required") from error
            except InstagramVerificationRequired as error:
                await self._freeze(
                    current,
                    AccountStatus.VERIFICATION_REQUIRED,
                    _verification_message(error),
                    client,
                )
                raise AccountUnavailable("Instagram verification is required") from error
            except InstagramReauthenticationRequired as error:
                await self._freeze(
                    current,
                    AccountStatus.REAUTH_REQUIRED,
                    "Instagram rejected the saved session. Sign in again; Lillygram did not retry.",
                    client,
                )
                raise AccountUnavailable("The saved Instagram session was rejected") from error
            except InstagramRejected as error:
                await asyncio.to_thread(
                    self.storage.save_session, current.id, client.settings(), current.status
                )
                raise UpstreamRejected("Instagram rejected the request") from error
            await asyncio.to_thread(
                self.storage.save_session,
                current.id,
                client.settings(),
                AccountStatus.ACTIVE,
                None,
            )
            return result

    def _ensure_available(self, record: AccountRecord) -> None:
        if record.status != AccountStatus.ACTIVE:
            message = record.challenge_message or "Sign in again to use this account"
            raise AccountUnavailable(message)

    async def _enforce_login_limit(self, record: AccountRecord) -> None:
        since = datetime.now(UTC) - timedelta(hours=1)
        count = await asyncio.to_thread(
            self.storage.count_events, record.id, "login", since
        )
        if count >= self.settings.login_limit_per_hour:
            raise RateLimitExceeded(
                f"The login safety limit of {self.settings.login_limit_per_hour} attempts per hour was reached"
            )
        await asyncio.to_thread(self.storage.record_event, record.id, "login")

    async def _enforce_limit(self, record: AccountRecord, category: str) -> None:
        if category == "write":
            writes_enabled_at = record.created_at + timedelta(days=self.settings.warmup_days)
            if datetime.now(UTC) < writes_enabled_at:
                raise WarmupRequired(
                    f"Posting unlocks after {writes_enabled_at.isoformat()} while this account warms up"
                )
            limit = self.settings.write_limit_per_hour
        else:
            limit = self.settings.read_limit_per_hour
        since = datetime.now(UTC) - timedelta(hours=1)
        count = await asyncio.to_thread(
            self.storage.count_events, record.id, category, since
        )
        if count >= limit:
            raise RateLimitExceeded(
                f"The {category} safety limit of {limit} requests per hour was reached"
            )
        await asyncio.to_thread(self.storage.record_event, record.id, category)

    async def _pace(self, category: str) -> None:
        bounds = (
            self.settings.write_delay_seconds
            if category == "write"
            else self.settings.read_delay_seconds
        )
        await self._sleep(self._random_uniform(*bounds))

    async def _freeze(
        self,
        record: AccountRecord,
        status: AccountStatus,
        message: str,
        client: InstagramClient,
    ) -> None:
        await asyncio.to_thread(
            self.storage.save_session,
            record.id,
            client.settings(),
            status,
            message,
        )

    async def _lock_for(self, account_id: str) -> asyncio.Lock:
        async with self._locks_guard:
            lock = self._locks.get(account_id)
            if lock is None:
                lock = asyncio.Lock()
                self._locks[account_id] = lock
            return lock
