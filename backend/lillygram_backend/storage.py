from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
import threading
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Callable

from cryptography.fernet import Fernet, InvalidToken

from .models import Account, AccountStatus


@dataclass(frozen=True)
class AccountRecord:
    id: str
    username: str
    status: AccountStatus
    created_at: datetime
    settings: dict[str, Any]
    token_hash: str
    proxy_url: str | None
    challenge_message: str | None
    verification_method: str | None
    verification_context: dict[str, Any] | None
    verification_expires_at: datetime | None


class StorageError(RuntimeError):
    pass


class AccountStorage:
    """SQLite metadata plus Fernet-encrypted Instagram session state.

    Credentials are never accepted here. The encrypted blob contains only the
    instagrapi settings/session dictionary generated for one Instagram account.
    """

    def __init__(self, database_path: Path, encryption_key: str, warmup_days: int) -> None:
        self._database_path = database_path
        self._database_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self._fernet = Fernet(encryption_key.encode())
        except (ValueError, TypeError) as error:
            raise StorageError("LILLYGRAM_ENCRYPTION_KEY must be a valid Fernet key") from error
        self._warmup_days = warmup_days
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(database_path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        with self._connection:
            self._connection.execute("PRAGMA journal_mode=WAL")
            self._connection.execute("PRAGMA foreign_keys=ON")
            self._connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS accounts (
                    id TEXT PRIMARY KEY,
                    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    settings_blob BLOB NOT NULL,
                    token_hash TEXT NOT NULL UNIQUE,
                    proxy_blob BLOB,
                    challenge_message TEXT,
                    verification_method TEXT,
                    verification_blob BLOB,
                    verification_expires_at TEXT
                );
                CREATE TABLE IF NOT EXISTS request_events (
                    account_id TEXT NOT NULL,
                    category TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY(account_id) REFERENCES accounts(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS request_events_lookup
                    ON request_events(account_id, category, created_at);
                """
            )
            columns = {
                row["name"]
                for row in self._connection.execute("PRAGMA table_info(accounts)")
            }
            if "verification_method" not in columns:
                self._connection.execute(
                    "ALTER TABLE accounts ADD COLUMN verification_method TEXT"
                )
            if "verification_blob" not in columns:
                self._connection.execute(
                    "ALTER TABLE accounts ADD COLUMN verification_blob BLOB"
                )
            if "verification_expires_at" not in columns:
                self._connection.execute(
                    "ALTER TABLE accounts ADD COLUMN verification_expires_at TEXT"
                )

    @staticmethod
    def token_hash(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    def create_account(
        self,
        username: str,
        settings: dict[str, Any],
        proxy_url: str | None,
    ) -> tuple[AccountRecord, str]:
        token = secrets.token_urlsafe(48)
        account_id = str(uuid.uuid4())
        created_at = datetime.now(UTC)
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO accounts(
                    id, username, status, created_at, settings_blob,
                    token_hash, proxy_blob, challenge_message
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                (
                    account_id,
                    username.strip(),
                    AccountStatus.REAUTH_REQUIRED.value,
                    created_at.isoformat(),
                    self._encrypt_json(settings),
                    self.token_hash(token),
                    self._encrypt_text(proxy_url),
                ),
            )
        return self.get_by_id(account_id), token

    def get_or_create_account(
        self,
        username: str,
        settings_factory: Callable[[], dict[str, Any]],
        proxy_url: str | None,
    ) -> tuple[AccountRecord, str | None]:
        existing = self.get_by_username(username)
        if existing is not None:
            if proxy_url is not None and proxy_url != existing.proxy_url:
                self.set_proxy(existing.id, proxy_url)
                existing = self.get_by_id(existing.id)
            return existing, None
        return self.create_account(username, settings_factory(), proxy_url)

    def get_by_username(self, username: str) -> AccountRecord | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM accounts WHERE username = ? COLLATE NOCASE",
                (username.strip(),),
            ).fetchone()
        return self._decode_record(row) if row else None

    def get_by_id(self, account_id: str) -> AccountRecord:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM accounts WHERE id = ?", (account_id,)
            ).fetchone()
        if row is None:
            raise KeyError(account_id)
        return self._decode_record(row)

    def get_by_token(self, token: str) -> AccountRecord | None:
        digest = self.token_hash(token)
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM accounts WHERE token_hash = ?", (digest,)
            ).fetchone()
        return self._decode_record(row) if row else None

    def rotate_token(self, account_id: str) -> str:
        token = secrets.token_urlsafe(48)
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE accounts SET token_hash = ? WHERE id = ?",
                (self.token_hash(token), account_id),
            )
        return token

    def save_session(
        self,
        account_id: str,
        settings: dict[str, Any],
        status: AccountStatus = AccountStatus.ACTIVE,
        challenge_message: str | None = None,
    ) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                """
                UPDATE accounts
                SET settings_blob = ?, status = ?, challenge_message = ?,
                    verification_method = NULL, verification_blob = NULL,
                    verification_expires_at = NULL
                WHERE id = ?
                """,
                (self._encrypt_json(settings), status.value, challenge_message, account_id),
            )

    def save_verification(
        self,
        account_id: str,
        settings: dict[str, Any],
        method: str,
        challenge_message: str,
        context: dict[str, Any] | None = None,
        expires_at: datetime | None = None,
    ) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                """
                UPDATE accounts
                SET settings_blob = ?, status = ?, challenge_message = ?,
                    verification_method = ?, verification_blob = ?,
                    verification_expires_at = ?
                WHERE id = ?
                """,
                (
                    self._encrypt_json(settings),
                    AccountStatus.VERIFICATION_REQUIRED.value,
                    challenge_message,
                    method,
                    self._encrypt_json(context) if context else None,
                    expires_at.isoformat() if expires_at else None,
                    account_id,
                ),
            )

    def set_status(
        self,
        account_id: str,
        status: AccountStatus,
        challenge_message: str | None = None,
    ) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE accounts SET status = ?, challenge_message = ? WHERE id = ?",
                (status.value, challenge_message, account_id),
            )

    def set_proxy(self, account_id: str, proxy_url: str | None) -> None:
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE accounts SET proxy_blob = ? WHERE id = ?",
                (self._encrypt_text(proxy_url), account_id),
            )

    def count_events(self, account_id: str, category: str, since: datetime) -> int:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT COUNT(*) AS count FROM request_events
                WHERE account_id = ? AND category = ? AND created_at >= ?
                """,
                (account_id, category, since.isoformat()),
            ).fetchone()
        return int(row["count"])

    def record_event(self, account_id: str, category: str) -> None:
        now = datetime.now(UTC)
        cutoff = now - timedelta(hours=24)
        with self._lock, self._connection:
            self._connection.execute(
                "INSERT INTO request_events(account_id, category, created_at) VALUES (?, ?, ?)",
                (account_id, category, now.isoformat()),
            )
            self._connection.execute(
                "DELETE FROM request_events WHERE created_at < ?", (cutoff.isoformat(),)
            )

    def account_model(self, record: AccountRecord) -> Account:
        return Account(
            id=record.id,
            username=record.username,
            status=record.status,
            created_at=record.created_at,
            writes_enabled_at=record.created_at + timedelta(days=self._warmup_days),
            challenge_message=record.challenge_message,
            proxy_configured=record.proxy_url is not None,
            verification_method=record.verification_method,
            sms_pending=(
                record.verification_context is not None
                and record.verification_expires_at is not None
                and record.verification_expires_at > datetime.now(UTC)
            ),
        )

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def _decode_record(self, row: sqlite3.Row) -> AccountRecord:
        try:
            settings = self._decrypt_json(row["settings_blob"])
            proxy_url = self._decrypt_text(row["proxy_blob"])
            verification_context = (
                self._decrypt_json(row["verification_blob"])
                if row["verification_blob"]
                else None
            )
        except InvalidToken as error:
            raise StorageError(
                "Encrypted account data cannot be read with the configured key"
            ) from error
        return AccountRecord(
            id=row["id"],
            username=row["username"],
            status=AccountStatus(row["status"]),
            created_at=datetime.fromisoformat(row["created_at"]),
            settings=settings,
            token_hash=row["token_hash"],
            proxy_url=proxy_url,
            challenge_message=row["challenge_message"],
            verification_method=row["verification_method"],
            verification_context=verification_context,
            verification_expires_at=(
                datetime.fromisoformat(row["verification_expires_at"])
                if row["verification_expires_at"]
                else None
            ),
        )

    def _encrypt_json(self, value: dict[str, Any]) -> bytes:
        payload = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
        return self._fernet.encrypt(payload)

    def _decrypt_json(self, value: bytes) -> dict[str, Any]:
        decoded = self._fernet.decrypt(value)
        result = json.loads(decoded)
        if not isinstance(result, dict):
            raise StorageError("Stored Instagram settings are not an object")
        return result

    def _encrypt_text(self, value: str | None) -> bytes | None:
        return self._fernet.encrypt(value.encode()) if value else None

    def _decrypt_text(self, value: bytes | None) -> str | None:
        return self._fernet.decrypt(value).decode() if value else None
