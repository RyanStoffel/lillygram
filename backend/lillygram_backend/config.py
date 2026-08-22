from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    database_path: Path
    encryption_key: str
    allowed_origins: tuple[str, ...]
    read_limit_per_hour: int = 120
    write_limit_per_hour: int = 6
    login_limit_per_hour: int = 3
    warmup_days: int = 3
    read_delay_seconds: tuple[float, float] = (0.8, 2.5)
    write_delay_seconds: tuple[float, float] = (2.0, 6.0)
    max_upload_bytes: int = 100 * 1024 * 1024

    @classmethod
    def from_environment(cls) -> "Settings":
        key = os.environ.get("LILLYGRAM_ENCRYPTION_KEY", "")
        if not key:
            raise RuntimeError(
                "LILLYGRAM_ENCRYPTION_KEY is required; generate one with "
                "python -c 'from cryptography.fernet import Fernet; "
                "print(Fernet.generate_key().decode())'"
            )
        origins = tuple(
            item.strip()
            for item in os.environ.get("LILLYGRAM_ALLOWED_ORIGINS", "").split(",")
            if item.strip()
        )
        return cls(
            database_path=Path(
                os.environ.get("LILLYGRAM_DATABASE_PATH", "data/lillygram.sqlite3")
            ),
            encryption_key=key,
            allowed_origins=origins,
            read_limit_per_hour=int(
                os.environ.get("LILLYGRAM_READ_LIMIT_PER_HOUR", "120")
            ),
            write_limit_per_hour=int(
                os.environ.get("LILLYGRAM_WRITE_LIMIT_PER_HOUR", "6")
            ),
            login_limit_per_hour=int(
                os.environ.get("LILLYGRAM_LOGIN_LIMIT_PER_HOUR", "3")
            ),
            warmup_days=int(os.environ.get("LILLYGRAM_WARMUP_DAYS", "3")),
        )
