from fastapi.testclient import TestClient

from app.api.routes import openbao, registry
from app.main import app


class FakeOpenBao:
    def __init__(self):
        self.servers = {}
        self.credentials = {}
        self.auth_urls = {}

    async def write_server(
        self,
        name,
        provider,
        client_id,
        client_secret,
        scopes,
        auth_url_params,
        provider_options,
    ):
        self.servers[name] = {
            "provider": provider,
            "client_id": client_id,
            "client_secret": client_secret,
            "scopes": scopes,
        }

    async def auth_code_url(
        self,
        server,
        state,
        scopes,
        redirect_url,
    ):
        url = (
            "https://example.com/oauth/authorize?"
            f"state={state}"
        )
        self.auth_urls[state] = url
        return url

    async def write_credential(
        self,
        name,
        server,
        code,
        redirect_url,
    ):
        self.credentials[name] = {
            "server": server,
            "code": code,
        }

    async def read_credential(self, name):
        return "test-access-token"


fake_openbao = FakeOpenBao()

# Replace the module-level client used by the routes.
original_openbao = openbao
openbao = fake_openbao

import app.api.routes as routes

routes.openbao = fake_openbao
routes.oauth.openbao = fake_openbao

client = TestClient(app)


def setup_function():
    registry._providers.clear()
    fake_openbao.servers.clear()
    fake_openbao.credentials.clear()
    fake_openbao.auth_urls.clear()


def teardown_module():
    routes.openbao = original_openbao


def test_health():
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_register_provider_does_not_return_secret():
    response = client.post(
        "/providers",
        json={
            "name": "github",
            "provider": "github",
            "client_id": "test-client-id",
            "client_secret": "super-secret-value",
            "scopes": ["read:user", "user:email"],
        },
    )

    assert response.status_code == 201

    body = response.json()

    assert body["name"] == "github"
    assert body["provider"] == "github"
    assert body["client_id"] == "test-client-id"
    assert body["scopes"] == ["read:user", "user:email"]

    assert "client_secret" not in body
    assert "super-secret-value" not in response.text


def test_connect_returns_authorization_url():
    # Register provider first.
    response = client.post(
        "/providers",
        json={
            "name": "github",
            "provider": "github",
            "client_id": "test-client-id",
            "client_secret": "super-secret-value",
            "scopes": ["read:user"],
        },
    )

    assert response.status_code == 201

    response = client.post(
        "/providers/github/users/test-user/connect"
    )

    assert response.status_code == 200

    body = response.json()

    assert body["provider"] == "github"
    assert body["user"] == "test-user"
    assert body["state"]
    assert body["authorization_url"].startswith(
        "https://example.com/oauth/authorize?"
    )


def test_callback_writes_code_to_openbao():
    client.post(
        "/providers",
        json={
            "name": "github",
            "provider": "github",
            "client_id": "test-client-id",
            "client_secret": "super-secret-value",
            "scopes": ["read:user"],
        },
    )

    connect = client.post(
        "/providers/github/users/test-user/connect"
    )

    state = connect.json()["state"]

    response = client.get(
        "/callback",
        params={
            "code": "authorization-code",
            "state": state,
        },
    )

    assert response.status_code == 200

    body = response.json()

    assert body == {
        "status": "connected",
        "provider": "github",
        "user": "test-user",
    }

    assert fake_openbao.credentials["github:test-user"] == {
        "server": "github",
        "code": "authorization-code",
    }


def test_token_retrieval_is_async():
    client.post(
        "/providers",
        json={
            "name": "github",
            "provider": "github",
            "client_id": "test-client-id",
            "client_secret": "super-secret-value",
            "scopes": ["read:user"],
        },
    )

    response = client.get(
        "/github/test-user"
    )

    assert response.status_code == 202

    data = response.json()

    assert data["status"] == "pending"
    assert data["request_id"]
    assert data["location"] == response.headers["Location"]
    assert response.headers["Location"].endswith(
         f"/requests/{data['request_id']}"
    )
