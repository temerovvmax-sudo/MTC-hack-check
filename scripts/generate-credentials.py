#!/usr/bin/env python3
"""Create lab-only credentials. Re-running keeps the existing file."""

import json
import os
import secrets
import stat
import string
import sys

SPECIALS = "!@%^*-_=+"


def complex_password(length: int = 20) -> str:
    rng = secrets.SystemRandom()
    chars = [
        rng.choice(string.ascii_uppercase),
        rng.choice(string.ascii_lowercase),
        rng.choice(string.digits),
        rng.choice(SPECIALS),
    ]
    alphabet = string.ascii_letters + string.digits + SPECIALS
    chars.extend(rng.choice(alphabet) for _ in range(length - 4))
    rng.shuffle(chars)
    return "".join(chars)


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: generate-credentials.py ENV_PATH JSON_PATH", file=sys.stderr)
        sys.exit(2)
    env_path, json_path = sys.argv[1], sys.argv[2]
    if os.path.exists(env_path) and os.path.exists(json_path):
        print(f"credentials already present at {env_path}")
        return
    os.makedirs(os.path.dirname(env_path), exist_ok=True)
    data = {
        "POSTGRES_USER": "testy",
        "POSTGRES_PASSWORD": secrets.token_hex(16),
        "POSTGRES_DB": "testy",
        "SECRET_KEY": secrets.token_urlsafe(48),
        "SUPERUSER_USERNAME": "admin",
        "SUPERUSER_PASSWORD": complex_password(),
        "GRAFANA_ADMIN_USER": "admin",
        "GRAFANA_ADMIN_PASSWORD": complex_password(),
    }
    lines = [
        "# Local lab credentials generated at deploy time.",
        "# These are not production secrets and are not committed.",
        "# TestY superuser password has upper, lower, digit, and a special character.",
    ]
    for key, value in data.items():
        lines.append(f"{key}={value}")
    fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    fd = os.open(json_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.chmod(env_path, stat.S_IRUSR | stat.S_IWUSR)
    os.chmod(json_path, stat.S_IRUSR | stat.S_IWUSR)
    print(f"wrote {env_path}")


if __name__ == "__main__":
    main()
