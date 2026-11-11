FROM alpine:3

RUN apk add --no-cache bash restic docker-cli tzdata gzip

# Compose service names (not container names) of apps to freeze during the file snapshot
ENV PAUSE_SERVICES="prowlarr radarr sonarr qbittorrent forgejo opencloud radicale paperless jellyfin"

COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
