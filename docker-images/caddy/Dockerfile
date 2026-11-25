ARG CADDY_RELEASE=2.11.9

FROM caddy:${CADDY_RELEASE}-builder AS builder

RUN xcaddy build --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:${CADDY_RELEASE}

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
