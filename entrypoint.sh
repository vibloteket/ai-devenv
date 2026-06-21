#!/bin/sh
# Write git credentials from environment variables at runtime.
# Tokens only exist in docker-compose .env / container env — never in the image.

set -eu

GIT_CONFIG_DIR=/home/ai/.config/git
CODEBERG_USER=${CODEBERG_USER:-viblo-ai}
GITHUB_USER=${GITHUB_USER:-viblo-ai}

mkdir -p "$GIT_CONFIG_DIR"
chmod 700 "$GIT_CONFIG_DIR"

if [ -n "${CODEBERG_TOKEN:-}" ]; then
    printf 'https://%s:%s@codeberg.org\n' "$CODEBERG_USER" "$CODEBERG_TOKEN" > "$GIT_CONFIG_DIR/codeberg-credentials"
    chmod 600 "$GIT_CONFIG_DIR/codeberg-credentials"
    git config --global --replace-all credential.https://codeberg.org.helper "store --file=$GIT_CONFIG_DIR/codeberg-credentials"
fi

if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf 'https://%s:%s@github.com\n' "$GITHUB_USER" "$GITHUB_TOKEN" > "$GIT_CONFIG_DIR/github-credentials"
    chmod 600 "$GIT_CONFIG_DIR/github-credentials"
    git config --global --replace-all credential.https://github.com.helper "store --file=$GIT_CONFIG_DIR/github-credentials"
fi

exec "$@"
