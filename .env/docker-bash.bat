@echo off
rem Throwaway bash container. Compose holds the volumes/env; the command is passed here.
docker compose --env-file "%~dp0.env" -f "%~dp0docker-compose.yml" run --rm dev bash
