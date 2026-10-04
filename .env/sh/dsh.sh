#!/usr/bin/env bash
# Started by docker-dsh.bat inside the container.
#
# "dsh web" binds loopback only and rejects --host 0.0.0.0 as a usage error, so
# the container cannot be reached from the host directly. socat listens on
# 0.0.0.0:3080 and forwards to 127.0.0.1:3081 where dsh serves. The host browser
# opens http://localhost:3080, so the Host header stays on the loopback
# allowlist and the signed-cookie handshake works unchanged.
#
# Keep this file LF-only (no CRLF): bash rejects a shebang or command ending in
# a stray carriage return.
set -euo pipefail

socat TCP-LISTEN:3080,fork,reuseaddr TCP:127.0.0.1:3081 &
exec dsh web --port 3081 --no-open
