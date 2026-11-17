# GMS admin web (Next.js standalone output). Build context = repository root.
FROM node:22-alpine AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY apps/admin-web/package.json apps/admin-web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY apps/admin-web/ ./
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0
RUN addgroup -S gms && adduser -S gms -G gms
COPY --from=build --chown=gms:gms /app/.next/standalone ./
COPY --from=build --chown=gms:gms /app/.next/static ./.next/static
COPY --from=build --chown=gms:gms /app/public ./public
USER gms
EXPOSE 3000
CMD ["node", "server.js"]
