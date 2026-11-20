# The DSA API server as a container image.
#
# Two stages: the Dart SDK compiles the server to one native program, and
# only that program goes into a small Debian image (no SDK, no source code).
# Configuration comes from environment variables, the same names as in
# .env.example. See docker-compose.yml at the project root to run it with
# MySQL.

FROM dart:3.13.1 AS build
WORKDIR /src
# Packages first, so they're cached until pubspec changes.
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY bin ./bin
COPY lib ./lib
RUN dart pub get --offline && dart compile exe bin/server.dart -o dsa_server

FROM debian:bookworm-slim
# ca-certificates: HTTPS to Brevo (email) and Firebase (push).
# curl: the health check below. tzdata: UAE time in the logs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/*
ENV TZ=Asia/Dubai
# Runs as an ordinary user, never root.
RUN useradd --system --uid 10001 --no-create-home dsa
WORKDIR /app
COPY --from=build /src/dsa_server ./dsa_server
USER dsa
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://localhost:8080/health || exit 1
CMD ["/app/dsa_server"]
