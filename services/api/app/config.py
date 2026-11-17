from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All secrets come from the environment / secret manager. Nothing is hard-coded."""

    model_config = SettingsConfigDict(env_prefix="GMS_", env_file=".env", extra="ignore")

    database_url: str = Field(description="Restricted API login (member of gms_api only)")
    jwt_secret: str = Field(min_length=32)
    jwt_issuer: str = "gms-api"
    access_ttl_minutes: int = 15
    refresh_ttl_hours_web: int = 12
    refresh_ttl_days_mobile: int = 30
    login_max_failures: int = 5
    login_lock_minutes: int = 15
    pool_max: int = 10
    cors_origins: list[str] = []
    storage_backend: str = "filesystem"  # filesystem | s3
    storage_dir: str = "var/objects"
    s3_endpoint: str | None = None
    s3_access_key: str | None = None
    s3_secret_key: str | None = None
    s3_bucket: str = "gms-photos"
    s3_secure: bool = True
    max_photo_bytes: int = 8 * 1024 * 1024
    backup_dir: str = "var/backups"

    @field_validator("database_url")
    @classmethod
    def _plain_url(cls, v: str) -> str:
        return v.replace("postgresql+psycopg://", "postgresql://")


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
