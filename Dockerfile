# syntax=docker/dockerfile:1

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — build
#
# One Maven run produces the whole app: frontend-maven-plugin installs Node,
# builds the Vite bundle, and maven-resources-plugin copies it into the jar's
# static/ directory. The result is a single self-contained Spring Boot jar.
#
# Pinned to BUILDPLATFORM so a multi-arch build compiles natively once instead
# of running Maven and Node under QEMU for every target. The jar is bytecode —
# architecture only matters for the runtime stage.
# ─────────────────────────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /src

# Dependency layers first — they only invalidate when the manifests change.
COPY backend/pom.xml backend/pom.xml
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -f backend/pom.xml dependency:go-offline -DskipTests

COPY frontend/package.json frontend/package-lock.json frontend/
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -f backend/pom.xml \
      frontend:install-node-and-npm@install-node-and-npm \
      frontend:npm@npm-install

# Sources last — an edit here reuses every layer above.
COPY frontend/ frontend/
COPY backend/src backend/src

RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -f backend/pom.xml clean package -DskipTests \
 && cp backend/target/praxis-chess-*.jar /src/praxis-chess.jar

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — runtime
#
# JRE + Stockfish. Stockfish is a native binary the app spawns as a child
# process, so it must match the image architecture — installed per-target from
# the distro rather than copied from the build stage.
# ─────────────────────────────────────────────────────────────────────────────
FROM eclipse-temurin:21-jre-noble AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends stockfish curl \
 && rm -rf /var/lib/apt/lists/* \
 && test -x /usr/games/stockfish

RUN useradd --system --create-home --uid 10001 praxis
WORKDIR /app

COPY --from=build /src/praxis-chess.jar /app/praxis-chess.jar
COPY docker/application-docker.yml /app/config/application.yml

# Container defaults. Every one is overridable with -e; the config file itself
# can be replaced by bind-mounting over /app/config/application.yml. The DB
# password is deliberately not an ENV default — it is set by the caller and
# falls back inside application.yml, so it never bakes into image metadata.
ENV PRAXISCHESS_STOCKFISH_PATH=/usr/games/stockfish \
    SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/praxis_chess?ApplicationName=praxis-chess \
    SPRING_DATASOURCE_USERNAME=praxis_chess_user \
    PRAXISCHESS_OLLAMA_BASEURL=http://ollama:11434 \
    PRAXISCHESS_TTS_ENABLED=false \
    JAVA_OPTS="-XX:MaxRAMPercentage=75"

USER praxis
EXPOSE 8086

HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=10 \
  CMD curl -fsS http://127.0.0.1:8086/actuator/health || exit 1

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/praxis-chess.jar --spring.config.location=file:/app/config/application.yml"]

LABEL org.opencontainers.image.title="Praxis Chess" \
      org.opencontainers.image.description="Offline chess analytics and improvement system — Spring Boot + Stockfish + local LLM, frontend bundled." \
      org.opencontainers.image.source="https://github.com/RakshitRabugotra/Praxis-Chess"
