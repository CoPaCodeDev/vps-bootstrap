FROM oven/bun:1 AS build

WORKDIR /app

# Package-Manifeste zuerst fuer besseres Layer-Caching
COPY package.json bun.lock ./
COPY packages/core/package.json packages/core/package.json
COPY packages/cli/package.json packages/cli/package.json
COPY packages/mcp/package.json packages/mcp/package.json
COPY packages/acp/package.json packages/acp/package.json
COPY packages/docs/package.json packages/docs/package.json

RUN bun install --frozen-lockfile

# Source-Code kopieren und bauen
COPY . .
RUN bunx vite build

# --- Produktions-Image ---
FROM nginx:alpine

COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
