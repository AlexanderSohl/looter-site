# Top Down Looter site: Node server + game build + SQLite leaderboard.
# Build:  docker build -t looter-site .
# Run:    docker run -p 8080:8080 -v looter-data:/data looter-site
FROM node:20-bookworm-slim AS dependencies
WORKDIR /app
# Compilers are only a fallback in case better-sqlite3 has no prebuilt binary.
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:20-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8080 \
    DATABASE_FILE=/data/leaderboard.sqlite
COPY --from=dependencies /app/node_modules ./node_modules
COPY package.json server.js auth.js ./
COPY public ./public
# /data is the persistent volume: the database (accounts + runs) lives there.
RUN mkdir -p /data && chown -R node:node /data /app
USER node
VOLUME /data
EXPOSE 8080
CMD ["node", "server.js"]
