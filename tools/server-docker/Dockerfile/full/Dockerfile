# syntax=docker/dockerfile:1

# Single-container "full" LAN server for one game (server + certificate generator
# + battle-server-manager running BattleServer.exe under Wine). The game is
# selected at build time with --build-arg GAME=<age1|age2|age3|age4|athens>.
#
# BattleServer.exe is proprietary game content, baked in from the (gitignored)
# build context. This image must NOT be published to a public registry. Build it
# with tools/server-docker/build-push-full-ghcr.sh.
#
# Note: AoE II: DE has no macOS-native BattleServer, so macOS/Linux clients use
# the AoE II: DE Windows BattleServer.exe here (see server/BattleServers.md).

# ---- Wine runtime base ----
FROM alpine:3.24 AS runner
RUN apk add --no-cache wine \
 && WINEPREFIX=/wine WINEARCH=win64 WINEDEBUG=-all DISPLAY="" \
    wineboot --init 2>/dev/null || true \
 && rm -rf /wine/drive_c/windows/syswow64 \
           /wine/drive_c/windows/twain_32 \
           /wine/drive_c/windows/system32/gecko \
           /wine/drive_c/windows/Microsoft.NET \
           /wine/drive_c/windows/explorer.exe \
           /wine/drive_c/windows/winhlp32.exe \
           /wine/drive_c/windows/winsxs
ENV WINEPREFIX=/wine \
    WINEDEBUG=-all \
    WINEARCH=win64 \
    DISPLAY=""

# ---- Compile ----
FROM golang:1.26-alpine3.24 AS compiler
ARG GAME=age2
WORKDIR /app
COPY tools/server-docker/Dockerfile/full/go.work.template go.work
COPY common common
COPY battle-server-broadcast battle-server-broadcast
COPY server server
COPY server-genCert server-genCert
COPY battle-server-manager battle-server-manager
RUN mkdir -p build
RUN cp -r server/resources build/server-resources && rm -rf build/server-resources/windows build/server-resources/unix
RUN mkdir -p build/server-resources/certificates
RUN mkdir -p build/bsm-resources
RUN cp battle-server-manager/resources/config.game.toml "build/bsm-resources/config.${GAME}.toml"
RUN go build -ldflags="-s -w" -o build/server ./server
RUN go build -ldflags="-s -w" -o build/genCert ./server-genCert
RUN go build -ldflags="-s -w" -o build/battle-server-manager ./battle-server-manager

# ---- Compress ----
FROM alpine:3.24 AS compressor
RUN apk add --no-cache upx
WORKDIR /app
COPY --from=compiler /app/build/server server
COPY --from=compiler /app/build/genCert genCert
COPY --from=compiler /app/build/battle-server-manager battle-server-manager
RUN upx --lzma server genCert battle-server-manager

# ---- Execute ----
FROM runner
ARG GAME=age2
ENV GAME=${GAME}
# server: https + LAN announcement
EXPOSE 443/tcp
EXPOSE 31978/udp
# battle-server-manager
EXPOSE 27012/tcp
EXPOSE 27112/tcp
EXPOSE 27212/tcp
VOLUME /app/server/resources/certificates
VOLUME /app/logs
VOLUME /tmp/ageLANServer/battle-servers
# server (genCert one level below so its cert-folder resolution lands on
# /app/server/resources/certificates)
COPY --from=compiler /app/build/server-resources /app/server/resources
COPY --from=compressor /app/server /app/server/server
COPY --from=compressor /app/genCert /app/server/bin/genCert
# battle-server-manager
COPY --from=compiler /app/build/bsm-resources /app/battle-server-manager/resources
COPY --from=compressor /app/battle-server-manager /app/battle-server-manager/battle-server-manager
# Proprietary game binary, baked in from the (gitignored) build context.
COPY tools/server-docker/Dockerfile/full/BattleServer.exe /app/BattleServer.exe
COPY tools/server-docker/Dockerfile/full/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh \
    /app/server/server \
    /app/server/bin/genCert \
    /app/battle-server-manager/battle-server-manager
ENV AGELANSERVER_BATTLE_SERVER_MANAGER_Ports_Bs=27012 \
    AGELANSERVER_BATTLE_SERVER_MANAGER_Ports_WebSocket=27112 \
    AGELANSERVER_BATTLE_SERVER_MANAGER_Ports_OutOfBand=27212 \
    AGELANSERVER_BATTLE_SERVER_MANAGER_CertsPath=/app/server/resources/certificates \
    AGELANSERVER_BATTLE_SERVER_MANAGER_Executable_Path=/app/BattleServer.exe
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
