import secrets

from app.config import settings
from app.openbao.client import OpenBaoClient
from app.providers.registry import ProviderRegistry


class OAuthService:
    def __init__(
        self,
        openbao: OpenBaoClient,
        registry: ProviderRegistry,
    ) -> None:
        self.openbao = openbao
        self.registry = registry

        # OAuth state intentionally lives only in memory.
        self._states: dict[str, tuple[str, str]] = {}

    async def connect(
        self,
        provider_name: str,
        user: str,
    ) -> tuple[str, str]:
        provider = self.registry.get(provider_name)

        if provider is None:
            raise ValueError("provider not found")

        state = secrets.token_urlsafe(32)

        authorization_url = await self.openbao.auth_code_url(
            server=provider.name,
            state=state,
            scopes=provider.scopes,
            redirect_url=settings.redirect_url,
        )

        self._states[state] = (provider.name, user)

        return authorization_url, state

    async def callback(
        self,
        code: str,
        state: str,
    ) -> tuple[str, str]:
        state_data = self._states.pop(state, None)

        if state_data is None:
            raise ValueError("invalid or expired OAuth state")

        provider_name, user = state_data

        credential_name = f"{provider_name}:{user}"

        await self.openbao.write_credential(
            name=credential_name,
            server=provider_name,
            code=code,
            redirect_url=settings.redirect_url,
        )

        return provider_name, user
