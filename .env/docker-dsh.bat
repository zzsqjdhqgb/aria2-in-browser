@echo off
rem Web UI at http://localhost:3080. --service-ports publishes the compose port.
docker compose --env-file "%~dp0.env" -f "%~dp0docker-compose.yml" run --rm --service-ports dev bash /workspace/.env/sh/dsh.sh
