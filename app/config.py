from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    openbao_addr: str = "http://127.0.0.1:8200"
    openbao_token: str = ""
    redirect_url: str = "http://localhost:8000/callback"
    openbao_timeout_seconds: float = 10.0

    model_config = SettingsConfigDict(
        env_file=".env",
        env_prefix="",
        case_sensitive=False,
    )


settings = Settings()
