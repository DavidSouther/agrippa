# syntax=docker/dockerfile:1
# Context is workloads/resume (passed via -f by scripts/workloads-build.sh) -- the submodule tracks upstream verbatim and has no Dockerfile of its own.
#
# glibc, not alpine -- lightningcss-cli/biome's musl-native optional binaries don't install reliably under Alpine in a fresh, no-cache build.
FROM node:24 AS build
WORKDIR /src
COPY . .
# npm run build writes the static site into docs/.
RUN npm ci && npm run build

# Stage 2: a minimal static server. docs/ is a flat SSG output; /blog is a
# real directory (docs/blog/index.html), so nginx's own directory-index
# redirect handles it.
#
# absolute_redirect off: TLS terminates at the Gateway and this container
# only ever speaks HTTP -- nginx's default absolute redirect would 404
# there.
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
