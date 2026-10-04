@echo off
rem Build the image via compose. The dsh version is pinned in the Dockerfile.
docker compose --env-file "%~dp0.env" -f "%~dp0docker-compose.yml" build
