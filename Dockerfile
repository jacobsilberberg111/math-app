# Margin backend (deployed on Railway). The iPad app itself is built with Xcode/Playgrounds.
FROM node:22-alpine
WORKDIR /app
COPY server/package.json server/server.mjs ./
ENV NODE_ENV=production
USER node
EXPOSE 8080
CMD ["node", "server.mjs"]
