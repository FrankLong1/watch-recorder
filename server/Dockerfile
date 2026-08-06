# Base images are pinned to the same digests the agent-inbox queue already runs,
# so both services move together rather than drifting apart silently.
FROM oven/bun:1.2.23@sha256:6ebf306367da43ad75c4d5119563e24de9b66372929ad4fa31546be053a16f74 AS build

WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

COPY tsconfig.json ./
COPY src ./src
RUN bun build src/index.ts --target bun --outdir dist

FROM oven/bun:1.2.23-slim@sha256:9654aa08d4b7e778b84148921bab8edc1409c8d0a85707b8c801dd7cf1878971 AS runtime

ENV NODE_ENV=production \
    PORT=8080

WORKDIR /app
COPY --from=build /app/dist ./dist

USER bun
EXPOSE 8080
CMD ["bun", "run", "dist/index.js"]
