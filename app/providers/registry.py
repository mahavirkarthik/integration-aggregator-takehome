from dataclasses import dataclass
from threading import Lock


@dataclass(frozen=True)
class Provider:
    name: str
    provider: str
    client_id: str
    scopes: list[str]


class ProviderRegistry:
    def __init__(self) -> None:
        self._providers: dict[str, Provider] = {}
        self._lock = Lock()

    def register(self, provider: Provider) -> None:
        with self._lock:
            self._providers[provider.name] = provider

    def get(self, name: str) -> Provider | None:
        with self._lock:
            return self._providers.get(name)

    def exists(self, name: str) -> bool:
        with self._lock:
            return name in self._providers

    def list(self) -> list[Provider]:
        with self._lock:
            return list(self._providers.values())
