# syntax=docker/dockerfile:1

# Standalone, zero-config AoE II: DE LAN server.
# Bundles the server + the certificate generator so the container runs with no
# arguments, no compose and no external certificate step.

# ---- Compile ----
FROM golang:1.26-alpine3.24 AS compiler
WORKDIR /app
COPY tools/server-docker/Dockerfile/aoe2/go.work.template go.work
COPY common common
COPY battle-server-broadcast battle-server-broadcast
COPY server server
COPY server-genCert server-genCert
RUN mkdir build
RUN cp -r server/resources build/resources && rm -rf build/resources/windows build/resources/unix
RUN mkdir -p build/resources/certificates
RUN go build -ldflags="-s -w" -o build/server ./server
RUN go build -ldflags="-s -w" -o build/genCert ./server-genCert

# ---- Compress ----
FROM alpine:3.24 AS compressor
RUN apk add --no-cache upx
WORKDIR /app
COPY --from=compiler /app/build/server server
COPY --from=compiler /app/build/genCert genCert
RUN upx --lzma server genCert

# ---- Execute ----
FROM alpine:3.24
# https
EXPOSE 443/tcp
# LAN announcement
EXPOSE 31978/udp
VOLUME /app/server/resources/certificates
VOLUME /app/logs
WORKDIR /app/server
COPY --from=compiler /app/build/resources resources
COPY --from=compressor /app/server server
# genCert lives one level below the server so its cert-folder resolution
# (parent-of-parent of its own path) points at /app/server/resources/certificates.
COPY --from=compressor /app/genCert bin/genCert
COPY tools/server-docker/Dockerfile/aoe2/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh server bin/genCert
ENTRYPOINT ["/app/entrypoint.sh"]
