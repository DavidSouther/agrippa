# syntax=docker/dockerfile:1
# Builds trips.davidsouther.com (the `trips` workload) from the
# `workloads/trips` git submodule (github.com/davidsouther/trips, private, an
# @davidsouther/jiffies static-site generator). Built outside the submodule
# directory (context is `workloads/trips`, passed via `-f` from the repo root
# by scripts/workloads-build.sh) since the submodule tracks the real upstream
# repo verbatim -- no Dockerfile lives inside it.
#
# Stage 1: node:24 (glibc, NOT node:24-alpine) -- same rationale as
# resume.Dockerfile: lightningcss-cli and @biomejs/biome ship musl-native
# optional binaries that are not reliable under Alpine/musl in a fresh
# container.
FROM node:24 AS build
WORKDIR /src
COPY . .
# npm ci installs from the committed lockfile (trips is confirmed
# offline-buildable -- its trip data is a committed cache, no network fetch
# beyond npm ci itself); npm run build's own `prebuild` lifecycle hook (npm
# run check: tsc --noEmit + biome check) runs first, then css:bundle + the
# sitemap script + the jiffies SSG write the static site into docs/.
RUN npm ci && npm run build

# Stage 2: a minimal static server. No /healthz here -- only the personal
# site carries one (parent design decision 4); trips' own liveness/readiness
# probe targets plain `/`.
#
# `absolute_redirect off` matches resume.Dockerfile's own build-time finding:
# TLS terminates upstream at the shared Istio Gateway and this container's
# HTTPRoute binds only the `https` listener, so any directory-index redirect
# nginx emits must be scheme/host-less (relative) or it 404s at the Gateway.
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
