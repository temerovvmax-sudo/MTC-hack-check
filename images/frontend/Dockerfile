FROM node:18.13.0-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY . .
ARG VITE_APP_API_ROOT=https://api.testy.local
ARG VITE_APP_REPO_URL=https://gitlab-pub.yadro.com/testy/testy
ARG VITE_APP_BUG_REPORT_URL=mailto:testy@yadro.com
ENV VITE_APP_API_ROOT=${VITE_APP_API_ROOT} \
    VITE_APP_REPO_URL=${VITE_APP_REPO_URL} \
    VITE_APP_BUG_REPORT_URL=${VITE_APP_BUG_REPORT_URL} \
    GENERATE_SOURCEMAP=false
ARG NODE_HEAP=2048
ENV NODE_OPTIONS=--max_old_space_size=${NODE_HEAP}
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.27.5-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build /usr/share/nginx/html
EXPOSE 8080
