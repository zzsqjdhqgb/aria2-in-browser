@echo off
rem Open a shell in the one running container of this image, whether it was
rem started by compose ("run" / "up -d") or by a plain docker run. With zero or
rem several containers running this refuses to guess and exits with an error.
setlocal EnableExtensions DisableDelayedExpansion
set "IMAGE=dsh-dev:local"
for /f %%N in ('docker ps --filter "ancestor=%IMAGE%" --format "{{.ID}}" ^| find /c /v ""') do set "N=%%N"
if not defined N set "N=0"
if "%N%"=="0" (
    echo No running container for image %IMAGE%.
    echo Start one first: docker-bash.bat or docker-dsh.bat
    exit /b 1
)
if not "%N%"=="1" (
    echo %N% containers are running for image %IMAGE%. Refusing to attach, pick one yourself:
    docker ps --filter "ancestor=%IMAGE%" --format "  {{.ID}}  {{.Names}}"
    exit /b 1
)
for /f %%I in ('docker ps --filter "ancestor=%IMAGE%" --format "{{.ID}}"') do set "CID=%%I"
echo Attaching to %CID% ^(exiting this shell leaves the container running^)...
docker exec -it %CID% bash
