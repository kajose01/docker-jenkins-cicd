# Multi-stage: "test" runs the unit and integration tests, "runtime" is the image that ships
# Base image pinned by digest (tag for humans: node:24-alpine, an LTS line). To update: docker pull, read the new digest, rebuild, rescan.
FROM node:24-alpine@sha256:8a32c8cf649a49915a66e81e7a609223c708d0adabf288ee3f4077d765542f85 AS base
WORKDIR /app
COPY app/package.json ./
COPY app/src ./src

FROM base AS test
COPY app/test ./test
# Always succeeds: the exit status of the tests is saved in report/exit-code and judged by the Jenkinsfile,
# so the reports can be exported even when tests fail.
RUN mkdir -p report; \
    npm run test:ci > report/test-output.txt 2>&1; echo $? > report/exit-code; \
    cat report/test-output.txt; \
    true

FROM scratch AS test-report
COPY --from=test /app/report/ /

FROM base AS runtime
# Hardening: the app only needs node. Remove npm and yarn (and their bundled packages) from the shipped image,
# and upgrade just the two OpenSSL libraries flagged by the scan (a no-op if the base already has the fix).
RUN apk upgrade --no-cache libcrypto3 libssl3 \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg
ARG BUILD_NUMBER=dev
ARG GIT_SHA=unknown
ENV NODE_ENV=production BUILD_NUMBER=$BUILD_NUMBER GIT_SHA=$GIT_SHA
USER node
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "src/server.js"]
