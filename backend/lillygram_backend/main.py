
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, AsyncIterator

from fastapi import Depends, FastAPI, File, Form, Header, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .config import Settings
from .instagram import InstagrapiFactory
from .models import (
    Account,
    AppSettings,
    DirectMessage,
    DirectThread,
    LoginRequest,
    LoginResponse,
    Media,
    Page,
    Profile,
    ProfileSummary,
    ProxySettings,
    SMSRequest,
    SMSVerification,
    StoryTray,
    UploadResponse,
)
from .service import AccountService, BadRequest, ServiceError, Unauthorized
from .storage import AccountRecord, AccountStorage


def create_app(
    settings: Settings,
    storage: AccountStorage | None = None,
    service: AccountService | None = None,
) -> FastAPI:
    account_storage = storage or AccountStorage(
        settings.database_path, settings.encryption_key, settings.warmup_days
    )
    account_service = service or AccountService(
        settings, account_storage, InstagrapiFactory()
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        yield
        if storage is None:
            account_storage.close()

    app = FastAPI(
        title="Lillygram Backend",
        version="0.6.0",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
    )
    app.state.settings = settings
    app.state.storage = account_storage
    app.state.service = account_service

    if settings.allowed_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(settings.allowed_origins),
            allow_credentials=False,
            allow_methods=["GET", "POST", "PUT", "DELETE"],
            allow_headers=["Authorization", "Content-Type"],
        )

    @app.exception_handler(ServiceError)
    async def service_error_handler(_, error: ServiceError) -> JSONResponse:
        return JSONResponse(
            status_code=error.status_code,
            content={"error": {"code": error.code, "message": error.message}},
        )

    async def current_account(
        authorization: Annotated[str | None, Header()] = None,
    ) -> AccountRecord:
        if not authorization or not authorization.startswith("Bearer "):
            raise Unauthorized("A bearer token is required")
        return await account_service.authenticate(authorization.removeprefix("Bearer "))

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/auth/login", response_model=LoginResponse)
    async def login(request: LoginRequest) -> LoginResponse:
        return await account_service.login(request)

    @app.post("/v1/auth/request-sms", response_model=Account)
    async def request_sms(
        request: SMSRequest,
        account: Annotated[AccountRecord, Depends(current_account)],
    ) -> Account:
        return await account_service.request_sms(account, request.password)

    @app.post("/v1/auth/verify-sms", response_model=Account)
    async def verify_sms(
        request: SMSVerification,
        account: Annotated[AccountRecord, Depends(current_account)],
    ) -> Account:
        return await account_service.verify_sms(account, request.code)

    @app.get("/v1/session", response_model=Account)
    async def session(
        account: Annotated[AccountRecord, Depends(current_account)],
    ) -> Account:
        return await account_service.session(account)

    @app.get("/v1/settings", response_model=AppSettings)
    async def get_settings(
        account: Annotated[AccountRecord, Depends(current_account)],
    ) -> AppSettings:
        return await account_service.app_settings(account)

    @app.put("/v1/settings/proxy", response_model=AppSettings)
    async def update_proxy(
        request: ProxySettings,
        account: Annotated[AccountRecord, Depends(current_account)],
    ) -> AppSettings:
        return await account_service.set_proxy(account, request.proxy_url)

    @app.get("/v1/feed", response_model=Page)
    async def feed(
        account: Annotated[AccountRecord, Depends(current_account)],
        cursor: str | None = Query(default=None, max_length=512),
    ) -> Page:
        return await account_service.timeline(account, cursor)

    @app.get("/v1/stories", response_model=list[StoryTray])
    async def stories(
        account: Annotated[AccountRecord, Depends(current_account)],
    ) -> list[StoryTray]:
        return await account_service.stories(account)

    @app.get("/v1/search/accounts", response_model=list[ProfileSummary])
    async def search_accounts(
        account: Annotated[AccountRecord, Depends(current_account)],
        q: str = Query(min_length=2, max_length=64),
        limit: int = Query(default=20, ge=1, le=30),
    ) -> list[ProfileSummary]:
        return await account_service.search_accounts(account, q, limit)

    @app.get("/v1/profiles/{username}", response_model=Profile)
    async def profile(
        username: str,
        account: Annotated[AccountRecord, Depends(current_account)],
    ) -> Profile:
        return await account_service.profile(account, username)

    @app.get("/v1/profiles/{username}/media", response_model=Page)
    async def profile_media(
        username: str,
        account: Annotated[AccountRecord, Depends(current_account)],
        cursor: str | None = Query(default=None, max_length=512),
        limit: int = Query(default=24, ge=1, le=30),
    ) -> Page:
        return await account_service.profile_media(
            account, username, cursor, limit
        )

    @app.get("/v1/direct/threads", response_model=list[DirectThread])
    async def direct_threads(
        account: Annotated[AccountRecord, Depends(current_account)],
        limit: int = Query(default=20, ge=1, le=30),
    ) -> list[DirectThread]:
        return await account_service.direct_threads(account, limit)

    @app.get(
        "/v1/direct/threads/{thread_id}/messages",
        response_model=list[DirectMessage],
    )
    async def direct_messages(
        thread_id: str,
        account: Annotated[AccountRecord, Depends(current_account)],
        limit: int = Query(default=30, ge=1, le=50),
    ) -> list[DirectMessage]:
        return await account_service.direct_messages(account, thread_id, limit)

    @app.get("/v1/media/{media_id}", response_model=Media)
    async def media(
        media_id: str,
        account: Annotated[AccountRecord, Depends(current_account)],
        shared_reel: bool = Query(default=False),
    ) -> Media:
        return await account_service.media(account, media_id, shared_reel)

    @app.post("/v1/posts", response_model=UploadResponse)
    async def upload_post(
        account: Annotated[AccountRecord, Depends(current_account)],
        media_file: Annotated[UploadFile, File(alias="media")],
        caption: Annotated[str, Form(max_length=2200)] = "",
    ) -> UploadResponse:
        path, is_video = await _temporary_upload(media_file, settings)
        try:
            uploaded = await account_service.upload_post(
                account, path, caption, is_video
            )
            return UploadResponse(media=uploaded)
        finally:
            path.unlink(missing_ok=True)

    @app.post("/v1/stories", response_model=UploadResponse)
    async def upload_story(
        account: Annotated[AccountRecord, Depends(current_account)],
        media_file: Annotated[UploadFile, File(alias="media")],
    ) -> UploadResponse:
        path, is_video = await _temporary_upload(media_file, settings)
        try:
            uploaded = await account_service.upload_story(account, path, is_video)
            return UploadResponse(media=uploaded)
        finally:
            path.unlink(missing_ok=True)

    return app


async def _temporary_upload(
    upload: UploadFile, settings: Settings
) -> tuple[Path, bool]:
    content_type = (upload.content_type or "").lower()
    suffix_by_type = {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/heic": ".heic",
        "image/heif": ".heif",
        "video/mp4": ".mp4",
        "video/quicktime": ".mov",
    }
    suffix = suffix_by_type.get(content_type)
    if suffix is None:
        raise BadRequest("Only JPEG, PNG, HEIC, MP4, and QuickTime media are supported")
    payload = await upload.read(settings.max_upload_bytes + 1)
    if len(payload) > settings.max_upload_bytes:
        raise BadRequest("The upload exceeds the configured size limit")
    if not payload:
        raise BadRequest("The upload is empty")
    handle = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
    try:
        handle.write(payload)
        return Path(handle.name), content_type.startswith("video/")
    finally:
        handle.close()


def build_default_app() -> FastAPI:
    return create_app(Settings.from_environment())

