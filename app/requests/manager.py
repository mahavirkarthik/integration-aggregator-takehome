from dataclasses import dataclass
from datetime import datetime, timezone
from threading import Lock
from uuid import uuid4


@dataclass
class RequestState:
    request_id: str
    status: str
    provider: str
    user: str
    token: str | None = None
    error: str | None = None
    created_at: datetime | None = None


class RequestManager:
    def __init__(self) -> None:
        self._requests: dict[str, RequestState] = {}
        self._lock = Lock()

    def create(self, provider: str, user: str) -> RequestState:
        request = RequestState(
            request_id=str(uuid4()),
            status="pending",
            provider=provider,
            user=user,
            created_at=datetime.now(timezone.utc),
        )

        with self._lock:
            self._requests[request.request_id] = request

        return request

    def get(self, request_id: str) -> RequestState | None:
        with self._lock:
            return self._requests.get(request_id)

    def complete(self, request_id: str, token: str) -> None:
        with self._lock:
            request = self._requests.get(request_id)

            if request is None:
                return

            request.status = "completed"
            request.token = token

    def fail(self, request_id: str, error: str) -> None:
        with self._lock:
            request = self._requests.get(request_id)

            if request is None:
                return

            request.status = "failed"
            request.error = error
