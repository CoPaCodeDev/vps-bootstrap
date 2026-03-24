FROM oven/bun:1 AS source

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN git clone --depth 1 https://github.com/open-pencil/open-pencil.git .
RUN bun install --frozen-lockfile

# --- App Build (Web-UI) ---
FROM source AS app-build
RUN bunx vite build

FROM nginx:alpine AS app
COPY --from=app-build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80

# --- MCP Build ---
FROM source AS mcp-build
RUN cd packages/mcp && bun run build

FROM oven/bun:1-slim AS mcp
WORKDIR /app
COPY --from=mcp-build /app/packages/mcp/dist ./dist
COPY --from=mcp-build /app/packages/mcp/package.json ./package.json
COPY --from=mcp-build /app/packages/core ./packages/core
COPY --from=mcp-build /app/node_modules ./node_modules

ENV HOST=0.0.0.0
ENV PORT=7600
ENV WS_PORT=7601
EXPOSE 7600 7601
CMD ["bun", "run", "dist/index.js"]
