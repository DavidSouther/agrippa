# syntax=docker/dockerfile:1
# Context is workloads/trips (passed via -f by scripts/workloads-build.sh) -- the submodule tracks upstream verbatim and has no Dockerfile of its own.
#
# glibc, not alpine -- lightningcss-cli/biome's musl-native optional binaries don't install reliably under Alpine in a fresh, no-cache build.
FROM node:24 AS build
WORKDIR /src
COPY . .
# trips is offline-buildable -- its trip data is a committed cache, no
# network fetch beyond npm ci itself. npm run build writes the static site
# into docs/.
RUN npm ci && npm run build

# Stage 2: a minimal static server. No /healthz block -- unlike resume's
# image, this one doesn't serve one.
#
# absolute_redirect off -- same reason as resume.Dockerfile: TLS terminates
# at the Gateway, this container only speaks HTTP.
FROM nginx:alpine
COPY --from=build /src/docs /usr/share/nginx/html
RUN <<'EOF' cat > /etc/nginx/conf.d/default.conf
server {
    listen 80;
    root /usr/share/nginx/html;
    absolute_redirect off;

    location / {
        try_files $uri $uri/ $uri.html =404;
    }
}
EOF
