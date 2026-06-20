# Build stage
FROM node:20-alpine AS builder
WORKDIR /app
# better-sqlite3 compiles a native binding under musl — needs a toolchain.
RUN apk add --no-cache python3 make g++
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
# Drop dev deps but keep the compiled native module for the final stage.
RUN npm prune --omit=dev

# Production stage (no toolchain; reuse the builder's compiled node_modules)
FROM node:20-alpine AS production
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3001
COPY package*.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
EXPOSE 3001
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3001/api/health || exit 1
CMD ["node", "dist/server.js"]
