@echo off
rem Build the image via compose. To change the dsh version, edit ARG DSH_VERSION in Dockerfile.
docker compose --env-file "%~dp0.env" -f "%~dp0docker-compose.yml" build
