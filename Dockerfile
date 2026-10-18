# Multi-stage: "test" runs the unit and integration tests, "runtime" is the image that ships
FROM node:20-alpine AS base
WORKDIR /app
COPY app/package.json ./
COPY app/src ./src

FROM base AS test
COPY app/test ./test
RUN npm test

FROM base AS runtime
ARG BUILD_NUMBER=dev
ARG GIT_SHA=unknown
ENV NODE_ENV=production BUILD_NUMBER=$BUILD_NUMBER GIT_SHA=$GIT_SHA
USER node
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "src/server.js"]
