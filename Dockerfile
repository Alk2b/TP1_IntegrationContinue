# Stage 1 on installe les outils lourds pour compiler better-sqlite3
FROM node:20-alpine AS builder
RUN apk add --no-cache python3 make g++
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm prune --omit=dev

# Stage 2 on garde uniquement que ce qui est nécessaire pour l'exécution
FROM node:20-alpine
RUN apk add --no-cache wget
WORKDIR /app
COPY --from=builder --chown=node:node /app .
USER node
EXPOSE 3000
HEALTHCHECK CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1
CMD ["node", "src/server.js"]