from abc import ABC, abstractmethod
from typing import Any

import httpx


class OpenBaoError(RuntimeError):
    pass


class OpenBaoClient(ABC):
    @abstractmethod
    async def write_server(
        self,
        name: str,
        provider: str,
        client_id: str,
        client_secret: str,
        scopes: list[str],
        auth_url_params: dict[str, str],
        provider_options: dict[str, str],
    ) -> None:
        raise NotImplementedError

    @abstractmethod
    async def auth_code_url(
        self,
        server: str,
        state: str,
        scopes: list[str],
        redirect_url: str,
    ) -> str:
        raise NotImplementedError

    @abstractmethod
    async def write_credential(
        self,
        name: str,
        server: str,
        code: str,
        redirect_url: str,
    ) -> None:
        raise NotImplementedError

    @abstractmethod
    async def read_credential(self, name: str) -> str:
        raise NotImplementedError


class HttpOpenBaoClient(OpenBaoClient):
    def __init__(
        self,
        address: str,
        token: str,
        timeout: float = 10.0,
    ) -> None:
        self.base_url = address.rstrip("/")
        self.token = token
        self.timeout = timeout

    def _headers(self) -> dict[str, str]:
        return {
            "X-Vault-Token": self.token,
	    "X-Vault-Request": "true",
            "Content-Type": "application/json",
        }

    async def _request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if not self.token:
            raise OpenBaoError("OPENBAO_TOKEN is not configured")

        url = f"{self.base_url}/v1/{path.lstrip('/')}"

        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.request(
                method,
                url,
                headers=self._headers(),
                json=payload,
            )

        if response.status_code >= 400:
            # Deliberately do not include request payloads because they may
            # contain client secrets or OAuth authorization codes.
            try:
                body = response.json()
                errors = body.get("errors", [])
                message = "; ".join(str(error) for error in errors)
            except ValueError:
                message = response.text[:200]

            raise OpenBaoError(
                f"OpenBao request failed: {response.status_code}: {message}"
            )

        if not response.content:
            return {}

        try:
            return response.json()
        except ValueError as exc:
            raise OpenBaoError("OpenBao returned invalid JSON") from exc

    async def write_server(
        self,
        name: str,
        provider: str,
        client_id: str,
        client_secret: str,
        scopes: list[str],
        auth_url_params: dict[str, str],
        provider_options: dict[str, str],
    ) -> None:
        payload: dict[str, Any] = {
            "name": name,
            "provider": provider,
            "client_id": client_id,
            "client_secret": client_secret,
        }


        if auth_url_params:
            payload["auth_url_params"] = auth_url_params

        if provider_options:
            payload["provider_options"] = provider_options

        await self._request(
            "PUT",
            f"oauth2/servers/{name}",
            payload,
        )

    async def auth_code_url(
        self,
        server: str,
        state: str,
        scopes: list[str],
        redirect_url: str,
    ) -> str:
        payload: dict[str, Any] = {
            "server": server,
            "state": state,
            "scopes": scopes,
            "redirect_url": redirect_url,
        }

        response = await self._request(
            "PUT",
            "oauth2/auth-code-url",
            payload,
        )

        url = response.get("data", {}).get("url") or response.get("url")

        if not url:
            raise OpenBaoError("OpenBao did not return an authorization URL")

        return str(url)

    async def write_credential(
        self,
        name: str,
        server: str,
        code: str,
        redirect_url: str,
    ) -> None:
        payload = {
            "server": server,
            "code": code,
            "redirect_url": redirect_url,
        }

        await self._request(
            "PUT",
            f"oauth2/creds/{name}",
            payload,
        )

    async def read_credential(self, name: str) -> str:
        response = await self._request(
            "GET",
            f"oauth2/creds/{name}",
        )

        data = response.get("data", response)
        token = data.get("access_token")

        if not token:
            raise OpenBaoError("OpenBao did not return an access token")

        return str(token)
