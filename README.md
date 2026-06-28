# Hermes Gateway on Docker

Runs the **Hermes Agent gateway inside a Linux container** — all messaging
platforms (Telegram, WhatsApp, and anything else you enable) served from one
supervised process, against your existing native Hermes install.

**Why this exists (the Catalina motivation):** on macOS 10.15 Catalina, the
Baileys WhatsApp bridge's native npm dependencies refuse to build — they target
macOS 11+ and crash with `dyld: Symbol not found: _SecTrustCopyCertificateChain`.
The same wall hits other modern native binaries. Running the gateway in Linux
sidesteps it entirely: Baileys (and everything else) compiles cleanly, while your
agent's brain — config, memory, model/STT keys — stays exactly where it is. The
approach isn't Catalina-specific, though; it's a clean way to run the gateway
anywhere, and the same files move to a Linux host nearly unchanged.

Based on the **official `nousresearch/hermes-agent` image**, which installs
Hermes into one clean tree, ships Node 22 + ffmpeg, and disables runtime
dependency installs — so the gateway can't end up reporting "telegram not
installed" while telegram sits in a different Python tree (the failure mode of a
hand-rolled image).

**Nothing about your existing install moves.** The container mounts your real
`$HOME/.hermes` and runs against the same config, memory, sessions, and keys.
Your host venv is never touched — the container uses the image's own runtime.

---

## Quick start (recommended)

Put all four files in one folder, then from that folder, as your normal Hermes
user:

```
chmod +x setup.sh
./setup.sh
```

That script: writes a host-specific `.env` (auto-filled from your shell), flips
`allow_lazy_installs: false` in your `config.yaml` if needed, builds the image,
starts the gateway, and prints the next steps. It's safe to re-run.

If your Hermes data dir isn't `$HOME/.hermes`, point it explicitly:
```
HERMES_DATA=/path/to/.hermes ./setup.sh
```

Then **pair WhatsApp** (interactive QR — scan from your chosen BOT number):
```
docker compose exec hermes-gateway hermes whatsapp
```

---

## Manual steps (if you'd rather not use the script)

### 1. Create the compose `.env` (host paths/IDs only — NOT your secrets)
Auto-fills from your shell, so no hand-editing of paths. Note the **unquoted**
`EOF` — that's deliberate so the shell expands the values as it writes:
```
cat > .env <<EOF
HOST_UID=$(id -u)
HOST_GID=$(id -g)
HERMES_DATA=$HOME/.hermes
HERMES_ENV_FILE=$HOME/.hermes/.env
EOF
```

### 2. Disable runtime lazy installs in your config
Prevents Hermes from pip-installing platform deps at runtime into a stray
user-site dir (the cause of the "telegram not installed" warning). Only flip if
it's currently `true`:
```
grep -n allow_lazy_installs "$HOME/.hermes/config.yaml"
# if it shows ': true', change to false (GNU sed):
sed -i 's/allow_lazy_installs: *true/allow_lazy_installs: false/' "$HOME/.hermes/config.yaml"
# macOS/BSD sed instead:
# sed -i '' 's/allow_lazy_installs: *true/allow_lazy_installs: false/' "$HOME/.hermes/config.yaml"
```

### 3. Build and start
```
docker compose build --no-cache
docker compose up -d --force-recreate
docker compose logs --tail=30 hermes-gateway
```

### 4. Pair WhatsApp
```
docker compose exec hermes-gateway hermes whatsapp
```

---

## Verifying it worked

You want Telegram to **connect** in the logs (not "python-telegram-bot not
installed"). Confirm the gateway and telegram share ONE Python tree:
```
docker compose exec hermes-gateway sh -c 'which hermes; head -1 $(which hermes); python -c "import telegram; print(telegram.__file__)"'
```
The `hermes` shebang Python and `telegram.__file__` should live under the same
install tree. If they split across `/usr/local` and `/home/*/.local`, lazy
installs are still on somewhere — recheck step 2.

WhatsApp session persists at `/data/whatsapp/session/` on your disk (i.e.
`~/.hermes/whatsapp/session/`), so it survives restarts — no re-scanning each
time.

---

## WhatsApp: pairing, config, and who can message the bot

### Pairing (once)
```
docker compose exec hermes-gateway hermes whatsapp
```
Enter the BOT's number in full international format, no `+` (US = `1` +
10-digit number, e.g. `1XXXXXXXXXX`). Scan the QR from that number's WhatsApp →
Settings → Linked Devices → Link a Device. A `code 515` reconnect right after
pairing is **normal** Baileys handshake noise, not an error.

**Pair only ONCE.** Repeated re-pairing in a short span can trigger a
`device_removed` / `401` logout (see Troubleshooting). The session persists at
`/data/whatsapp/session/`, so you do NOT need to re-pair after restarts or
config changes.

### Who the bot listens to (mode + allowed users)
These live in your **`.env`** — NOT config.yaml, whose `whatsapp: {}` block is
empty and unused. Edit `~/.hermes/.env` directly on the Mac (save as plain
text — TextEdit: Format → Make Plain Text first; or use nano), then
`docker compose restart hermes-gateway`.

```
WHATSAPP_ENABLED=true
WHATSAPP_MODE=self-chat             # or: allowlist
WHATSAPP_ALLOWED_USERS=1XXXXXXXXXX  # comma-separated, full intl format, no +
```

- `self-chat` — bot only answers messages the BOT number sends to itself (the
  "Message Yourself" chat); allowed-users is the bot's own number.
- `allowlist` — bot answers any number listed in `WHATSAPP_ALLOWED_USERS`. This
  is how you let your **personal** number message the bot: set `allowlist` and
  add your personal number, e.g.
  `WHATSAPP_ALLOWED_USERS=1XXXXXXXXXX,1YYYYYYYYYY` (bot number, then your
  personal number). Then from your personal
  WhatsApp, open a normal chat TO the bot number (not "Message Yourself").

**Numbers must be complete** — a truncated number is silently rejected with no
error (every message ignored). US = `1` + 10 digits = 11 total.

**Safe vs unsafe number use.** The bot is *linked* to the bot number — that's
the number carrying Baileys ban risk. Your personal number as an
*allowlisted sender* is just a human texting a contact: not running automation,
not exposed to ban risk. The risky thing would be *pairing* (scanning the QR
from) your personal number — don't.

### Watching WhatsApp traffic live
The gateway runs under s6, so `docker compose logs` shows only the init
sequence, not live traffic. The real logs are files under `/data`:
```
docker compose exec hermes-gateway sh -c 'tail -f /data/whatsapp/bridge.log'  # WhatsApp in/out
docker compose exec hermes-gateway sh -c 'tail -f /data/logs/gateway.log'     # routing
docker compose exec hermes-gateway sh -c 'tail -f /data/logs/agent.log'       # agent reasoning
```
`hermes gateway logs` does NOT exist — tail the files. `hermes gateway status`
confirms it's running.

---

## Google Workspace (Gmail / Calendar / Drive) — OAuth setup

The bundled `google-workspace` skill connects Gmail, Calendar, Drive, Docs,
Sheets, and Contacts via OAuth. Two things make this fiddly in the container,
both solved here:

**Always run the skill's `setup.py` with Hermes's own Python**, never bare
`python3`. Bare `python3` is the system interpreter (`/usr/bin/python3`) — PEP
668 "externally managed" and missing the Google libs — which produces a *false*
"dependency install failed" error. Use `/opt/hermes/.venv/bin/python`. (The
Dockerfile pre-installs the Google libs into that venv so they survive rebuilds.)

**The OAuth flow is three SEPARATE commands** — `setup.py` arguments are
mutually exclusive, so you cannot combine `--client-secret`, `--auth-url`, and
`--auth-code`. This version also does NOT accept `--services` or `--format`.

Setup, once per Google account (run on the Mac):
```
GP=/opt/hermes/.venv/bin/python
SU=/data/skills/productivity/google-workspace/scripts/setup.py

# 1. Register the client secret JSON (from Google Cloud → OAuth Desktop client).
#    Keep it under /data so it persists.
docker compose exec hermes-gateway $GP $SU --client-secret /data/google_client_secret.json

# 2. Generate the auth URL (separate command). Open it in the Mac browser and
#    authorize. The browser fails on http://localhost:1 after approval —
#    EXPECTED. Copy the ENTIRE redirected URL from the address bar.
docker compose exec hermes-gateway $GP $SU --auth-url

# 3. Exchange the pasted URL (quote it — contains & and ?):
docker compose exec hermes-gateway $GP $SU --auth-code "http://localhost:1/?...code=...&scope=..."

# 4. Verify:
docker compose exec hermes-gateway $GP $SU --check    # prints AUTHENTICATED
```
Token saves to `/data/google_token.json` (persists, auto-refreshes); client
secret at `/data/google_client_secret.json`. Both on the mounted volume.

The redirect URL from step 2 contains a **live, single-use OAuth code** — treat
it as private and exchange it promptly (it expires in minutes).

If Google shows **Error 403: access_denied**, your account isn't a test user on
the Cloud project (app in Testing mode) — add it at Google Cloud Console →
Audience → Test users.

**Per-profile / multiple accounts.** Each Hermes profile is isolated with its
own `~/.hermes`, so each gets its own `google_token.json` for a different Google
account. Repeat the flow per profile (how `setup.py` selects the profile inside
the container still needs confirming when setting up the 2nd account).

---

## Important operational notes

- **One gateway at a time.** Each platform (Telegram, etc.) allows only one
  active connection per bot token. If the Mac-native `hermes gateway` is still
  running, stop it before relying on the container — two listeners on the same
  token conflict. Let the container be THE gateway (it handles Telegram +
  WhatsApp together). Your native `hermes` CLI for direct terminal use is fine.

- **Not always-on.** Docker Desktop only runs while your host user is logged in
  and the Mac is awake. The gateway pauses on logout/sleep. A truly always-on
  setup needs a small Linux host — but this gets WhatsApp working today.

- **Ban risk + dedicated number (Baileys).** This is the unofficial WhatsApp Web
  protocol; Meta can restrict accounts that look automated. Use a **dedicated
  number, not your personal one** — and there's a hard technical reason too: the
  bridge uses one authenticated session per number, so the bot number can't
  double as your normal personal WhatsApp on the same device. A **virtual number
  (e.g. Google Voice)** is the clean choice. You pick it at pairing time.

- **Permissions on the mounted volume.** The official image runs as its own
  user. If you hit "permission denied" reading/writing the mounted data dir,
  uncomment the `user:` line in `docker-compose.yml` (it's prefilled from your
  `.env` HOST_UID/HOST_GID) and recreate.

- **Memory headroom.** If the build or first WhatsApp pairing stalls or gets
  OOM-killed, raise Docker Desktop → Settings → Resources → Memory to 4GB+.

---

## Troubleshooting

**"No adapter available for telegram" / "python-telegram-bot not installed"**
The running container can't import the platform dep from the gateway's own
Python. With the official image this should not happen; if it does:
1. Confirm step 2 (lazy installs off) actually took — `grep allow_lazy_installs`
   in your `config.yaml`.
2. Rebuild clean: `docker compose build --no-cache && docker compose up -d --force-recreate`.
   `up` alone reuses the old image; a failed build silently leaves the old one
   running.
3. Run the split-check command under "Verifying it worked".

**`FROM nousresearch/hermes-agent:latest` fails to pull**
If the official image isn't pullable (renamed/private/offline), tell me and we
switch to a from-scratch Dockerfile (python:3.11-slim + Node 22 + `pip install
"hermes-agent[all]"`) with lazy-installs disabled. The config flip in step 2
fixes the dep-split on either base.

**Gateway starts but acts like a fresh install (no Telegram credential)**
The image may expect a different mount path. This setup sets `HERMES_HOME=/data`
and mounts your data there; if the gateway ignores it, adjust the volume target
in `docker-compose.yml` to match the image's expected home and recreate.

**raft / aiohttp warnings**
Harmless — raft is an optional platform you're not using. Ignore it.

**WhatsApp paired but bot never replies**
Work through these in order:
1. Did you restart after pairing/config changes? `docker compose restart hermes-gateway`.
   A running gateway can hold a stale session.
2. Tail `/data/whatsapp/bridge.log` and send a test message. What you see tells you which:
   - `self_chat_mode_rejects_non_self` on a message from your personal number →
     you're still in `self-chat` mode. Switch `WHATSAPP_MODE=allowlist` and add
     the number (see the WhatsApp section).
   - Nothing at all on send → bridge not receiving; check `hermes gateway status`
     and that the message went to the right number.
   - Message accepted/processed but no reply on phone → send-back issue; check
     `/data/logs/agent.log` for errors.
3. Truncated allowed-users number silently rejects everything — verify the full
   number including country code (no `+`).

**`device_removed` / `401` / "Logged out. Delete session and restart"**
The linked device was invalidated (often from repeated re-pairing, or WhatsApp
dropping it). A restart will NOT fix this — the session must be cleared and
re-paired once, cleanly:
```
docker compose stop hermes-gateway && docker compose start hermes-gateway
docker compose exec hermes-gateway sh -c 'rm -rf /data/whatsapp/session/* && echo cleared'
docker compose exec hermes-gateway hermes whatsapp   # pair ONCE, scan from the BOT number
docker compose restart hermes-gateway
```
Then check WhatsApp → Linked Devices on the bot's phone to confirm the new link.

**Gateway warns session "not paired" at a path that doesn't match the bridge**
If the gateway looks for creds at `/data/platforms/whatsapp/session/` but the
bridge writes to `/data/whatsapp/session/` (or vice-versa), it reports "not
paired" despite a working session. Confirm where the session actually is
(`ls /data/whatsapp/session/`) and that `hermes whatsapp` and the gateway agree
on the path before re-pairing — re-pairing into the wrong path just burns
another session.

**The `hermes whatsapp` wizard won't change the mode**
It only edits the allowed-users list and offers re-pair; it never switches
self-chat ↔ allowlist. Change `WHATSAPP_MODE` by editing `~/.hermes/.env`
directly (see the WhatsApp section), not via the wizard.
