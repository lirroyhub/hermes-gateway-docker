# Hermes Agent gateway — based on the OFFICIAL Nous image.
#
# Why base on nousresearch/hermes-agent:latest instead of building from
# python:slim ourselves:
#   - It already installs Hermes into ONE immutable tree (no /usr/local vs
#     ~/.local split — the thing that made the gateway report "telegram not
#     installed" even though telegram was importable elsewhere).
#   - It already disables runtime lazy-dep installs (the official image sets the
#     internal bridge var that maps to security.allow_lazy_installs: false), so
#     nothing scatters new packages into a user-site dir at first run.
#   - Node 22 (WhatsApp/Baileys bridge), ffmpeg (voice memos), and the platform
#     SDKs are already present and built for Linux — no Catalina dyld wall.
#
# This image carries ONLY code/runtime. All real state — config, memory,
# sessions, model/STT keys — stays in your host Hermes data dir (HERMES_DATA,
# typically ~/.hermes) and is mounted at runtime (see docker-compose.yml).

FROM nousresearch/hermes-agent:latest

# Point Hermes at the mounted data dir. The official image respects HERMES_HOME.
ENV HERMES_HOME=/data

# Belt-and-suspenders against the dep-split failure mode, even though the base
# image already handles it: never resolve imports from a user-site dir, and
# never let pip do --user installs. Harmless if redundant.
ENV PYTHONNOUSERSITE=1 \
    PIP_USER=0

# NOTE: We deliberately do NOT create our own user or reinstall Hermes here.
# The official image already runs as its intended user with the correct tree.
# If you need host-UID file ownership on the mounted volume, prefer the compose
# `user:` override (see docker-compose.yml) over rebuilding the image.

# The base image's default entrypoint runs the gateway; we make it explicit so
# behavior is obvious. If the base image already CMDs the gateway this is a
# no-op; if it drops you into a CLI, this ensures gateway mode.
CMD ["hermes", "gateway"]
