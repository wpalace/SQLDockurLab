#!/bin/sh
# Console gateway. Runs INSIDE the runtime image (lab-novnc, lab-base-console).
# Usage: gateway.sh PORT=TARGET...   TARGET is unix:/path/to/vnc.sock or host:port.
# Starts one websockify per argument on $LAB_CONSOLE_BIND:PORT (default 127.0.0.1). Each one
# serves noVNC and accepts a WebSocket only with the console token (?token=, TokenFile plugin)
# and a same-port loopback Origin (console_auth.LoopbackOrigin). The token is read from
# /run/lab/console-token (mounted read-only from the gitignored secrets/console-token). The
# per-port token files go to /run/lab-console-tokens, which the caller mounts as tmpfs.
set -eu
bind=${LAB_CONSOLE_BIND:-127.0.0.1}
token_file=/run/lab/console-token
[ -s "$token_file" ] || {
  echo "gateway: missing $token_file" >&2
  exit 1
}
token=$(cat "$token_file")
tokens=/run/lab-console-tokens
mkdir -p "$tokens"
chmod 700 "$tokens"
export PYTHONPATH=/opt/lab-console
for spec in "$@"; do
  port=${spec%%=*}
  target=${spec#*=}
  case $target in
    unix:*) target="unix_socket:${target#unix:}" ;;
    *) ;;
  esac
  printf '%s: %s\n' "$token" "$target" >"$tokens/$port"
  # Security control: websockify logs each request path, which contains the token. Keep its
  # output discarded, and do not add --verbose, --log-file or --record (TC7 checks docker logs).
  websockify --web /usr/share/novnc \
    --token-plugin TokenFile --token-source "$tokens/$port" \
    --auth-plugin console_auth.LoopbackOrigin \
    "$bind:$port" >/dev/null 2>&1 &
done
wait
