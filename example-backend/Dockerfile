# Conduit dispatcher — a single always-on web process.
# uv-based; the project is run (not installed: package = false), so app/ and bot/
# are imported from the working directory, and the bot subprocess is spawned with
# cwd pinned to the project root by the dispatcher.
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# Dependency layer first (cached unless the manifest/lock changes). README is copied
# because pyproject references it; --frozen installs exactly what uv.lock pins; --no-dev
# drops test-only deps. package=false means there's no project to build here.
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev

# Application code (imported from cwd).
COPY . .

# The dispatcher binds the platform-injected $PORT, or 8000 locally.
EXPOSE 8000
CMD ["sh", "-c", "uv run --no-dev uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
