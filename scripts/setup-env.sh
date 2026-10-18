#!/usr/bin/env bash
# Creates .env (git-ignored): random admin password, Docker Hub token typed at a hidden prompt, docker group id
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { echo ".env already exists; delete it to recreate"; exit 0; }
read -rsp "Docker Hub access token (input is hidden): " TOKEN; echo
[ -n "$TOKEN" ] || { echo "empty token"; exit 1; }
umask 077
{
  echo "JENKINS_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=\n')"
  echo "DOCKERHUB_TOKEN=$TOKEN"
  echo "DOCKER_GID=$(getent group docker | cut -d: -f3)"
} > .env
echo ".env written (mode 600). The Jenkins login is user admin, password in .env"
