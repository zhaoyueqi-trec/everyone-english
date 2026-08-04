# syntax=docker/dockerfile:1
#
# 构建 1000h-portal (Nuxt3 SSR 应用) 的多阶段 Dockerfile。
# 这是一个 yarn workspaces monorepo,根目录还有 enjoy(Electron 客户端,依赖
# sqlite3/ffmpeg 等原生模块)和 1000-hours(VitePress 文档站),我们只想为
# 1000h-portal 安装依赖,所以用 `yarn workspaces focus` 只安装它自己需要的包,
# 避免把 enjoy 那一堆原生编译依赖也装进来。
#
# 构建时必须把 build context 设为仓库根目录(不是 1000h-portal 目录),
# 因为需要读取根目录的 package.json / yarn.lock / .yarn 才能正确安装依赖:
#   docker build -f 1000h-portal/Dockerfile -t <image> .

FROM node:20-bookworm-slim AS base
WORKDIR /app
RUN corepack enable

# ---------- 1. 只安装 1000h-portal 需要的依赖 ----------
FROM base AS deps

# 先只拷贝构建依赖关系所需要的最小文件集合,这样源码变化时
# Docker 层缓存依然能命中这一层,不用每次都重新 yarn install。
COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn ./.yarn
COPY enjoy/package.json ./enjoy/package.json
COPY 1000-hours/package.json ./1000-hours/package.json
COPY 1000h-portal/package.json ./1000h-portal/package.json

# workspaces focus 需要额外插件
RUN yarn plugin import workspace-tools
RUN yarn workspaces focus 1000h-portal

# ---------- 2. 构建 ----------
FROM deps AS build
COPY 1000h-portal ./1000h-portal
RUN yarn workspace 1000h-portal build

# Nuxt3/Nitro 的 node-server 预设会把服务端代码和它需要的依赖
# 一起打包进 .output/server,产物是自包含的,运行时不需要再装 node_modules。

# ---------- 3. 运行时镜像 ----------
FROM node:20-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000 \
    HOST=0.0.0.0

COPY --from=build /app/1000h-portal/.output ./.output

EXPOSE 3000
USER node
CMD ["node", ".output/server/index.mjs"]
