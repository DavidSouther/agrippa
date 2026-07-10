# syntax=docker/dockerfile:1
# Builds davidsouther.com (the `resume` workload) from the `workloads/resume`
# git submodule (github.com/davidsouther/resume, an @davidsouther/jiffies
# static-site generator). Built outside the submodule directory (context is
# `workloads/resume`, passed via `-f` from the repo root by
# scripts/workloads-build.sh) since the submodule tracks the real upstream
# repo verbatim -- no Dockerfile lives inside it.
#
# Stage 1: node:24 (glibc, NOT node:24-alpine) -- the upstream repo's
# devDependencies include lightningcss-cli and @biomejs/biome, both of which
# ship musl-native optional binaries that npm's optional-dependency
# resolution does not reliably install under Alpine/musl in a fresh,
# no-lockfile-cache container. glibc avoids that whole class of failure.
FROM node:24 AS build
WORKDIR /src
COPY . .
# npm ci installs from the committed lockfile; npm run build's own `prebuild`
# lifecycle hook (npm run check: tsc --noEmit + biome check) runs first,
# then css:bundle + the sitemap script + the jiffies SSG write the static
# site into docs/.
RUN npm ci && npm run build

# Stage 2: a minimal static server. docs/ is the jiffies SSG's flat output --
# build-verified: /blog is a real directory (docs/blog/index.html), so
# nginx's directory-index behavior 301-redirects /blog -> /blog/ under a
# plain `try_files` rule with no extra rewrite needed.
#
# BUILD-TIME FINDING: TLS is terminated upstream at the shared Istio Gateway
# (mode: Terminate); this container only ever speaks plain HTTP, and its
# HTTPRoute is bound to the Gateway's `https` listener only (no `http`
# listener attachment) -- so nginx's default *absolute* directory redirect
# (Location: http://<host>/blog/, scheme hardcoded from its own $scheme,
# which is always "http" here) sends the client to a plain-HTTP request that
# has no matching route and 404s at the Gateway. `absolute_redirect off`
# makes nginx emit a scheme/host-less relative Location (`/blog/`), so the
# client's own follow-up request reuses whatever scheme/host it already
# used -- correct regardless of where TLS is terminated.
FROM nginx:alpine
COPY --from=build /src/docs /usr/share/nginx/html
RUN <<'EOF' cat > /etc/nginx/conf.d/default.conf
server {
    listen 80;
    root /usr/share/nginx/html;
    absolute_redirect off;

    location = /healthz {
        return 200 "OK";
        add_header Content-Type text/plain;
    }

    location / {
        try_files $uri $uri/ $uri.html =404;
    }
}
EOF
