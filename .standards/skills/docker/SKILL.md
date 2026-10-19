---
name: docker
description: "House coding standard for Dockerfiles and Docker Compose v5. Use when writing, editing, or reviewing Dockerfile*, *.dockerfile, compose*.yaml, docker-compose*.yml, or .dockerignore."
---

# Docker & Compose Standards

> **Before calling work done:** run the formatter and linter checks in the Formatting section (`hadolint Dockerfile && yamllint -c .yamllint.yaml . && docker compose config --quiet`) and fix every finding. Reference config: `.hadolint.yaml and .yamllint.yaml` beside this file, which `sync-standards.sh` installs at the project root.

**Targets:** Docker Engine 29.x with BuildKit, and Docker Compose v5.x (v5.6.0, Oct 2026), using the Compose Specification. Lifecycle hooks and jobs need Compose v5.3 or later.

Containers are deployment artifacts. Build them to be small, reproducible, and safe by default.

## Base Images

- Pin every base image by **tag and digest**. Tags move; digests don't.
- Prefer slim, distroless, or hardened minimal bases. Use Alpine only when you have tested musl compatibility.
- Let Renovate or Dependabot bump digests. Don't edit them by hand.
- Start Dockerfiles with `# syntax=docker/dockerfile:1` so you get current BuildKit features.

```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.14-slim@sha256:<digest>
```

## Layer Ordering & Cache

- Copy dependency manifests first, install, then copy source.
- Use BuildKit **cache mounts** for package managers instead of baking caches into layers.
- Keep a strict `.dockerignore` (`.git`, `node_modules`, `.env`, build output).

```dockerfile
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen --no-dev
COPY src/ ./src/
```

## Multi-Stage Builds

- Build in one stage, run in another. Compilers and SDKs never ship to production.
- Name stages (`AS build`, `AS runtime`) and copy only artifacts.

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:<digest> AS build
RUN dotnet publish -c Release -o /out

FROM mcr.microsoft.com/dotnet/aspnet:10.0@sha256:<digest> AS runtime
COPY --from=build /out /app
```

## Non-Root Users

- Every runtime image ends with a non-root `USER` that has a fixed UID.
- Never set `privileged: true`. Add only the specific `cap_add` you need, and prefer `read_only: true`.

```dockerfile
RUN useradd --uid 10001 --create-home app
USER 10001
```

## Healthchecks & Startup Order

- Every long-running service defines a healthcheck, including `start_period` for slow starters.
- Use the long form of `depends_on` with a condition. The short list form only waits for the container to *start*.
- Run migrations as one-shot services that the app waits on with `service_completed_successfully`.

```yaml
services:
  migrate:
    image: myapp
    command: ["./migrate"]
    depends_on:
      db: { condition: service_healthy }
  api:
    depends_on:
      migrate: { condition: service_completed_successfully }
  db:
    image: postgres:18@sha256:<digest>
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      retries: 5
      start_period: 30s
```

## Resource Limits

- Set memory and CPU limits on every production service.
- Use `restart: unless-stopped` for services and `restart: "no"` for one-shot jobs.

```yaml
deploy:
  resources:
    limits: { cpus: "1.0", memory: 512M }
```

## Naming & File Layout

- Name the file `compose.yaml`. Drop the obsolete top-level `version:` key.
- Use lowercase kebab-case role names for services (`api`, `worker`, `postgres`). Don't set `container_name`.
- Set the project with `name:`.

## Formatting

Code is formatted for human readability and review. A formatter settles layout so reviewers can focus on logic.

- **Dockerfiles:** lint with **hadolint** in CI. Write instructions in uppercase, and put one package per line, sorted, with continuation backslashes, so each change is a one-line diff.
- **Compose:** run `docker compose config --quiet` in CI. Format YAML with Prettier (or check it with `yamllint`): 2-space indent, no tabs, lines under 120 characters.
- Keep a consistent key order in each service: `image`/`build`, `command`, `environment`, `ports`, `volumes`, `depends_on`, `healthcheck`, `deploy`.
- Use flow style (`{ a: b }`) only for short maps. Use block style for anything longer. Sort `environment` keys.
- Put a blank line between services. Write comments that explain *why* (a pinned workaround, an opened port), not *what*.
- Don't mix reformatting with behavior changes in one PR.

```bash
hadolint Dockerfile && docker compose config --quiet && npx prettier --check "**/compose*.yaml"
```

```dockerfile
# Before
RUN apt-get update && apt-get install -y curl git ca-certificates && rm -rf /var/lib/apt/lists/*

# After
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
 && rm -rf /var/lib/apt/lists/*
```

## Environment Variables & Secrets

- Use `.env` for local, non-sensitive defaults only. Commit `.env.example`, never `.env`.
- Provide runtime credentials through Compose `secrets:` (`/run/secrets/*`) or a platform secret store.
- Provide build-time credentials through **BuildKit secret mounts**, never `ARG` or `ENV`. Both persist in image history.
- Use `${VAR:?error}` to fail fast on required variables.

```dockerfile
RUN --mount=type=secret,id=pip_conf,target=/etc/pip.conf pip install -r requirements.txt
```

## Dev vs Prod

- `compose.yaml` is the production-shaped baseline.
- `compose.override.yaml` (loaded automatically) holds dev-only conveniences: debug ports and relaxed limits.
- Use **`develop.watch`** with `docker compose watch` for live reload instead of large bind mounts. Use `sync` for source changes and `rebuild` for manifest changes.
- Use **`profiles`** for optional tools (`admin`, `mocks`). Use **`include`** to compose self-contained sub-stacks.

```yaml
develop:
  watch:
    - { action: sync, path: ./src, target: /app/src, ignore: [__pycache__] }
    - { action: rebuild, path: pyproject.toml }
```

```bash
docker compose -f compose.yaml -f compose.prod.yaml up -d
```

## Avoid

- `latest` tags or unpinned images
- Running as root, or using `privileged: true`
- Secrets in images, build args, or committed `.env` files
- Short-form `depends_on` and `sleep` loops in place of health conditions
- Publishing database ports to the host in production

## Sources

- Sohail Saifi, "Docker Compose in 2026: The Parts of the Spec That Most Tutorials Skip" (Medium, Jun 2026)
- Filip Kosowski, "Docker Compose: Multi-File Composition" (Medium, Apr 2026)
- Docker Compose release notes, v5.x (github.com/docker/compose/releases)
