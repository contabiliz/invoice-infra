#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["PyJWT[crypto]", "httpx", "python-dotenv"]
# ///
"""
Generate a GitHub App installation access token.

Usage:
    uv run scripts/github_app_token.py

Reads from .env in the repo root (invoice-infra/.env). Required keys:
    GITHUB_APP_ID          — numeric App ID (Settings → Developer settings → GitHub Apps)
    GITHUB_APP_PRIVATE_KEY — path to the .pem private key file downloaded from GitHub
    GITHUB_APP_INSTALL_ID  — installation ID (Settings → Developer settings → GitHub Apps → Install)

Output:
    Prints the installation token to stdout so it can be captured:
        export GITHUB_TOKEN=$(uv run scripts/github_app_token.py)
        docker compose up -d --build
"""

import os
import sys
import time
from pathlib import Path

import httpx
import jwt  # PyJWT
from dotenv import load_dotenv

# Load .env from the repo root (one level up from scripts/)
load_dotenv(Path(__file__).parent.parent / ".env")


def _load_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        print(f"error: {name} is not set", file=sys.stderr)
        sys.exit(1)
    return value


def generate_app_jwt(app_id: str, private_key_pem: str) -> str:
    now = int(time.time())
    payload = {
        "iat": now - 60,   # issued 60 s ago — absorbs clock skew
        "exp": now + 540,  # 9 min — GitHub max is 10 min
        "iss": app_id,
    }
    return jwt.encode(payload, private_key_pem, algorithm="RS256")


def get_installation_token(app_jwt: str, installation_id: str) -> str:
    url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
    headers = {
        "Authorization": f"Bearer {app_jwt}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    response = httpx.post(url, headers=headers)
    response.raise_for_status()
    return response.json()["token"]


def main() -> None:
    app_id = _load_env("GITHUB_APP_ID")
    key_path = _load_env("GITHUB_APP_PRIVATE_KEY")
    install_id = _load_env("GITHUB_APP_INSTALL_ID")

    try:
        private_key_pem = open(key_path).read()
    except OSError as e:
        print(f"error: cannot read private key at {key_path!r}: {e}", file=sys.stderr)
        sys.exit(1)

    app_jwt = generate_app_jwt(app_id, private_key_pem)
    token = get_installation_token(app_jwt, install_id)
    print(token)


if __name__ == "__main__":
    main()
