# Running Praxis Chess in Docker

The image bundles everything the app itself needs — the Spring Boot backend, the
compiled React frontend, and the Stockfish binary — behind a single port. What
stays outside are the two things that hold state or a GPU: **PostgreSQL** and
**Ollama**.

```
ghcr.io/rakshitrabugotra/praxis-chess:latest    # linux/amd64, linux/arm64
```

---

## The short version

```bash
docker compose -f docker-compose.app.yml up -d
```

Then open <http://localhost:8086>.

That starts three containers — the app, PostgreSQL, and Ollama — on a shared
network with sane defaults. The schema creates itself on first boot.

Before your first sync, tell it whose games to fetch:

```bash
PRAXISCHESS_CHESSCOM_USERNAME=your_handle docker compose -f docker-compose.app.yml up -d
```

Ollama starts empty. Analysis needs its models, so pull them once (~9 GB, and
it is a one-shot container that exits when done):

```bash
docker compose -f docker-compose.app.yml --profile bootstrap up ollama-init
```

Everything else works before that finishes — sync, Stockfish evaluation, drills,
and insights are engine-driven. Only the written explanations, the pattern
report, the training plan, and Ask Prax need a model.

---

## Just the app container

If you already run Postgres and Ollama somewhere:

```bash
docker run -d --name praxis-chess -p 8086:8086 \
  -e PRAXISCHESS_CHESSCOM_USERNAME=your_handle \
  -e SPRING_DATASOURCE_URL='jdbc:postgresql://host.docker.internal:5432/praxis_chess' \
  -e SPRING_DATASOURCE_USERNAME=praxis_chess_user \
  -e SPRING_DATASOURCE_PASSWORD=praxis_chess_pass \
  -e PRAXISCHESS_OLLAMA_BASEURL='http://host.docker.internal:11434' \
  --add-host host.docker.internal:host-gateway \
  ghcr.io/rakshitrabugotra/praxis-chess:latest
```

`host.docker.internal` is how the container reaches services on your machine.
On Docker Desktop it resolves on its own; on Linux the `--add-host` line above
is what makes it work.

The container holds no state of its own — every game, analysis, and drill lives
in Postgres. Deleting and re-running it loses nothing.

---

## Configuration

Every setting in `docker/application-docker.yml` is overridable with an
environment variable. Spring's relaxed binding maps them by dropping dashes,
turning dots into underscores, and uppercasing:

| Variable | Default | What it does |
| --- | --- | --- |
| `PRAXISCHESS_CHESSCOM_USERNAME` | _(empty)_ | Chess.com handle to sync |
| `SPRING_DATASOURCE_URL` | `jdbc:postgresql://postgres:5432/praxis_chess` | Database JDBC URL |
| `SPRING_DATASOURCE_USERNAME` / `_PASSWORD` | `praxis_chess_user` / `praxis_chess_pass` | Database credentials |
| `PRAXISCHESS_OLLAMA_BASEURL` | `http://ollama:11434` | Ollama endpoint |
| `PRAXISCHESS_OLLAMA_MODEL` | `qwen2.5:7b` | Analysis model |
| `PRAXISCHESS_OLLAMA_REASONINGMODEL` | `qwen3:4b-instruct` | Ask Prax agent model (must support tool calling) |
| `PRAXISCHESS_STOCKFISH_PATH` | `/usr/games/stockfish` | Engine binary inside the image |
| `PRAXISCHESS_TTS_ENABLED` | `false` | Kokoro voice sidecar (not in this image) |
| `PRAXISCHESS_LOG_LEVEL` | `INFO` | Log level for `com.praxis` |
| `JAVA_OPTS` | `-XX:MaxRAMPercentage=75` | JVM flags |
| `PRAXIS_PORT` | `8086` | Host port in the compose stack |

For anything beyond these, bind-mount your own file over the baked-in one:

```bash
-v ./my-application.yml:/app/config/application.yml:ro
```

---

## GPU for Ollama

The Ollama container runs on CPU unless you hand it a GPU, and CPU inference on
a 7B model is slow enough to be worth avoiding. With the NVIDIA Container
Toolkit installed, add this to the `ollama` service:

```yaml
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

On Apple Silicon, Docker has no GPU access at all — run Ollama natively with
`brew install ollama` and point the app at
`PRAXISCHESS_OLLAMA_BASEURL=http://host.docker.internal:11434` instead.

---

## Building it yourself

```bash
docker build -t praxis-chess:local .
docker compose -f docker-compose.app.yml up -d --build
```

The build is one Maven run: `frontend-maven-plugin` installs Node and builds the
Vite bundle, `maven-resources-plugin` folds it into the jar's `static/`, and the
result is a single executable jar. First build downloads the Maven and npm
dependency trees; later ones reuse the cached layers unless a manifest changes.

---

## Publishing

`.github/workflows/docker-publish.yml` builds `linux/amd64` and `linux/arm64`
and pushes to GHCR on every push to `main` and every `v*.*.*` tag. It
authenticates with the repository's own `GITHUB_TOKEN`, so no secrets need
configuring — but the first published package is **private by default**. Make it
public once, under
`https://github.com/users/RakshitRabugotra/packages/container/praxis-chess/settings`,
and every `docker pull` afterwards works without a login.

Pull requests build the image to prove the Dockerfile still compiles, and push
nothing.

---

## Health and troubleshooting

The container reports health at `/actuator/health`, and the healthcheck allows a
90-second start period for JVM boot and schema creation.

**Stockfish not being used.** Check the startup log for `Stockfish ready:`. If
it says the engine failed to start, the binary at `PRAXISCHESS_STOCKFISH_PATH`
isn't executable — the app falls back to material counting rather than dying.

**Ollama connection refused.** The app tolerates a missing Ollama: analysis
still runs, explanations don't. Confirm reachability from inside the container:

```bash
docker exec praxis-chess-app curl -s http://ollama:11434/api/tags
```

**Database not ready.** `initialization-fail-timeout: -1` lets the app start
before Postgres does and connect when it appears, so a few early connection
warnings in the log are expected rather than fatal.
