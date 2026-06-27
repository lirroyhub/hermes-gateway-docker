#!/usr/bin/env bash
# One-shot setup for the Hermes Gateway on Docker (official-image based).
# Run this from the folder containing it, as your normal Hermes user:
#   chmod +x setup.sh && ./setup.sh
#
# It is safe to re-run. It does NOT touch your Hermes data except one config
# flip (allow_lazy_installs -> false), which it makes idempotently and only if
# needed.

set -euo pipefail

# --- Resolve host facts ----------------------------------------------------
HERMES_DATA_DEFAULT="$HOME/.hermes"
HERMES_DATA="${HERMES_DATA:-$HERMES_DATA_DEFAULT}"
HERMES_ENV_FILE="${HERMES_ENV_FILE:-$HERMES_DATA/.env}"

echo "→ Using Hermes data dir: $HERMES_DATA"

if [ ! -d "$HERMES_DATA" ]; then
  echo "✗ $HERMES_DATA does not exist. Set HERMES_DATA to your real Hermes dir:" >&2
  echo "    HERMES_DATA=/path/to/.hermes ./setup.sh" >&2
  exit 1
fi

if [ ! -f "$HERMES_ENV_FILE" ]; then
  echo "⚠ No secrets file at $HERMES_ENV_FILE — continuing, but model/STT keys"
  echo "  and platform tokens may be missing. Set HERMES_ENV_FILE if it's elsewhere."
fi

# --- Write the compose .env (host paths/IDs only; NOT your secrets) --------
# Unquoted heredoc so the shell expands these as it writes.
cat > .env <<EOF
HOST_UID=$(id -u)
HOST_GID=$(id -g)
HERMES_DATA=$HERMES_DATA
HERMES_ENV_FILE=$HERMES_ENV_FILE
EOF
echo "→ Wrote ./.env:"
sed 's/^/    /' .env

# --- Flip allow_lazy_installs -> false (prevents dep-tree scattering) ------
# The official image already disables lazy installs internally, but your
# mounted config.yaml can still carry allow_lazy_installs: true and win. Make
# it false so nothing tries to pip-install platform deps at runtime.
CFG="$HERMES_DATA/config.yaml"
if [ -f "$CFG" ]; then
  if grep -q 'allow_lazy_installs: *true' "$CFG"; then
    # macOS/BSD sed needs -i '' ; GNU sed needs -i. Handle both.
    if sed --version >/dev/null 2>&1; then
      sed -i 's/allow_lazy_installs: *true/allow_lazy_installs: false/' "$CFG"
    else
      sed -i '' 's/allow_lazy_installs: *true/allow_lazy_installs: false/' "$CFG"
    fi
    echo "→ Set allow_lazy_installs: false in $CFG"
  else
    echo "→ allow_lazy_installs already not 'true' (or no security block) — leaving as is"
  fi
else
  echo "→ No config.yaml yet — the gateway will create one; nothing to flip"
fi

# --- Clean any stray user-site copy from earlier from-scratch attempts -----
# Harmless if absent. Only relevant if you previously ran the python:slim build.
echo "→ (If a prior build scattered deps, they live inside old containers and"
echo "   will be discarded on the rebuild below — nothing to clean on the host.)"

# --- Build + start ---------------------------------------------------------
echo "→ Building image (pulls nousresearch/hermes-agent:latest)…"
docker compose build --no-cache

echo "→ Starting gateway…"
docker compose up -d --force-recreate

echo
echo "→ Recent logs:"
docker compose logs --tail=30 hermes-gateway || true

cat <<'NEXT'

──────────────────────────────────────────────────────────────────────
Next steps:

1. Confirm Telegram connects (no "not installed" warning) in the logs above.
   Sanity check that gateway + telegram share one Python tree:
     docker compose exec hermes-gateway sh -c 'which hermes; head -1 $(which hermes); python -c "import telegram; print(telegram.__file__)"'

2. Pair WhatsApp (interactive QR — scan from your chosen BOT number):
     docker compose exec hermes-gateway hermes whatsapp
   Session persists in <data>/platforms/whatsapp/session on your disk.

3. Stop the Mac-native `hermes gateway` if it's still running, so only ONE
   gateway holds your bot tokens (two listeners on one Telegram token conflict).
──────────────────────────────────────────────────────────────────────
NEXT
