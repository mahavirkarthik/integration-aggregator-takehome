import asyncio

from fastapi import APIRouter, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse

from app.api.models import (
    AsyncRequestResponse,
    ConnectResponse,
    ProviderRegistration,
    ProviderResponse,
    RequestStatusResponse,
)
from app.config import settings
from app.oauth.service import OAuthService
from app.openbao.client import HttpOpenBaoClient, OpenBaoError
from app.providers.registry import Provider, ProviderRegistry
from app.requests.manager import RequestManager


router = APIRouter()

registry = ProviderRegistry()
requests = RequestManager()

openbao = HttpOpenBaoClient(
    address=settings.openbao_addr,
    token=settings.openbao_token,
    timeout=settings.openbao_timeout_seconds,
)

oauth = OAuthService(
    openbao=openbao,
    registry=registry,
)


@router.post(
    "/providers",
    response_model=ProviderResponse,
    status_code=status.HTTP_201_CREATED,
)
async def register_provider(
    payload: ProviderRegistration,
) -> ProviderResponse:
    if registry.exists(payload.name):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="provider already exists",
        )

    try:
        await openbao.write_server(
            name=payload.name,
            provider=payload.provider,
            client_id=payload.client_id,
            client_secret=payload.client_secret,
            scopes=payload.scopes,
            auth_url_params=payload.auth_url_params,
            provider_options=payload.provider_options,
        )
    except OpenBaoError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=str(exc),
        ) from exc

    provider = Provider(
        name=payload.name,
        provider=payload.provider,
        client_id=payload.client_id,
        scopes=payload.scopes,
    )

    registry.register(provider)

    return ProviderResponse(
        name=provider.name,
        provider=provider.provider,
        client_id=provider.client_id,
        scopes=provider.scopes,
    )


@router.post(
    "/providers/{provider}/users/{user}/connect",
    response_model=ConnectResponse,
)
async def connect_user(
    provider: str,
    user: str,
) -> ConnectResponse:
    try:
        authorization_url, state = await oauth.connect(
            provider_name=provider,
            user=user,
        )
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        ) from exc
    except OpenBaoError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=str(exc),
        ) from exc

    return ConnectResponse(
        provider=provider,
        user=user,
        state=state,
        authorization_url=authorization_url,
    )


@router.get("/callback")
async def callback(
    code: str,
    state: str,
) -> JSONResponse:
    try:
        provider, user = await oauth.callback(
            code=code,
            state=state,
        )
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        ) from exc
    except OpenBaoError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=str(exc),
        ) from exc

    return JSONResponse(
        {
            "status": "connected",
            "provider": provider,
            "user": user,
        }
    )


@router.get(
    "/requests/{request_id}",
    response_model=RequestStatusResponse,
)
async def get_request(
    request_id: str,
) -> RequestStatusResponse:
    request_state = requests.get(request_id)

    if request_state is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="request not found",
        )

    return RequestStatusResponse(
        request_id=request_state.request_id,
        status=request_state.status,
        provider=request_state.provider,
        user=request_state.user,
        error=request_state.error,
    )


async def _retrieve_token(
    request_id: str,
    provider: str,
    user: str,
) -> None:
    try:
        token = await openbao.read_credential(
            name=f"{provider}:{user}",
        )

        requests.complete(request_id, token)

    except Exception:
        # Never expose OpenBao internals or credentials in application logs.
        requests.fail(
            request_id,
            "token retrieval failed",
        )


@router.get(
    "/{provider}/{user}",
    response_model=AsyncRequestResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def retrieve_token(
    request: Request,
    provider: str,
    user: str,
) -> AsyncRequestResponse:
    if registry.get(provider) is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="provider not found",
        )

    request_state = requests.create(
        provider=provider,
        user=user,
    )

    asyncio.create_task(
        _retrieve_token(
            request_state.request_id,
            provider,
            user,
        )
    )

    location = (
        f"{str(request.base_url).rstrip('/')}"
        f"/requests/{request_state.request_id}"
    )

    return Response(
        content=AsyncRequestResponse(
            request_id=request_state.request_id,
            status="pending",
            provider=provider,
            user=user,
            location=location,
        ).model_dump_json(),
        status_code=status.HTTP_202_ACCEPTED,
        media_type="application/json",
        headers={"Location": location},
    )
