FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/gandi \
    --with github.com/caddyserver/caddy/v2/modules/caddytelemetry

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
