from pydantic import BaseModel, Field, HttpUrl


class ProviderRegistration(BaseModel):
    name: str = Field(min_length=1)
    provider: str = Field(min_length=1)
    client_id: str = Field(min_length=1)
    client_secret: str = Field(min_length=1)
    scopes: list[str] = Field(default_factory=list)
    auth_url_params: dict[str, str] = Field(default_factory=dict)
    provider_options: dict[str, str] = Field(default_factory=dict)


class ProviderResponse(BaseModel):
    name: str
    provider: str
    client_id: str
    scopes: list[str]


class ConnectResponse(BaseModel):
    provider: str
    user: str
    state: str
    authorization_url: HttpUrl


class AsyncRequestResponse(BaseModel):
    request_id: str
    status: str
    provider: str
    user: str
    location: str


class RequestStatusResponse(BaseModel):
    request_id: str
    status: str
    provider: str
    user: str
    error: str | None = None


class ErrorResponse(BaseModel):
    error: str
