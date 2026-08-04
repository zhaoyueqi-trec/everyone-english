#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 1000h-portal 部署环境初始化 / 自检脚本
#
# 用法:把这个脚本传到 EC2 实例上,用有 sudo 权限的用户执行一次:
#   bash aws-server-setup.sh
#
# 它是幂等的(重复执行不会出问题),主要做几件事:
#   1. 确认 docker / docker compose 已就绪
#   2. 把当前用户加入 docker 组(这样 GitHub Actions SSH 上来后不用 sudo 也能跑 docker)
#   3. 创建部署会用到的目录 ~/apps/1000h-portal
#   4. 配置 docker 日志轮转,避免长期运行后日志把磁盘撑满
# ---------------------------------------------------------------------------
set -euo pipefail

APP_DIR="$HOME/apps/1000h-portal"

echo "== 1. 检查 docker =="
if ! command -v docker &>/dev/null; then
  echo "没有找到 docker 命令,请先安装: https://docs.docker.com/engine/install/"
  exit 1
fi
docker --version

echo ""
echo "== 2. 检查 docker compose (v2 插件) =="
if ! docker compose version &>/dev/null; then
  echo "没有检测到 'docker compose',尝试自动安装 docker-compose-plugin ..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get update -y
    sudo apt-get install -y docker-compose-plugin
  elif command -v yum &>/dev/null; then
    sudo yum install -y docker-compose-plugin
  else
    echo "无法识别包管理器,请手动安装: https://docs.docker.com/compose/install/linux/"
    exit 1
  fi
fi
docker compose version

echo ""
echo "== 3. 检查 curl(健康检查要用) =="
if ! command -v curl &>/dev/null; then
  echo "没有找到 curl,尝试安装..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get update -y && sudo apt-get install -y curl
  elif command -v yum &>/dev/null; then
    sudo yum install -y curl
  fi
fi
curl --version | head -1

echo ""
echo "== 4. 确认当前用户在 docker 组里 =="
if id -nG "$USER" | grep -qw docker; then
  echo "$USER 已经在 docker 组,免 sudo 可以直接跑 docker 命令。"
else
  echo "把 $USER 加入 docker 组..."
  sudo usermod -aG docker "$USER"
  echo "!! 这一步需要重新登录 SSH 会话才会生效,退出后重新连接一次再继续操作。"
fi

echo ""
echo "== 5. 创建应用目录 $APP_DIR =="
mkdir -p "$APP_DIR"
echo "已创建/已存在: $APP_DIR"

echo ""
echo "== 6. 配置 docker 日志轮转 =="
DAEMON_JSON=/etc/docker/daemon.json
NEED_RESTART=0
if [ ! -f "$DAEMON_JSON" ]; then
  echo '{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}' | sudo tee "$DAEMON_JSON" > /dev/null
  NEED_RESTART=1
elif ! grep -q "max-size" "$DAEMON_JSON"; then
  echo "!! $DAEMON_JSON 已存在但没有配置日志轮转,建议手动检查合并配置,这里不自动覆盖已有内容。"
else
  echo "日志轮转已经配置过了。"
fi

if [ "$NEED_RESTART" = "1" ]; then
  echo "重启 docker 使日志轮转配置生效..."
  sudo systemctl restart docker
fi

echo ""
echo "== 完成 =="
echo "接下来手动确认:"
echo "1. AWS 安全组(Security Group)已经放行入站 TCP 3000 端口(学习阶段先只对你自己的 IP 开放更安全)"
echo "2. 把这台服务器的公网 IP / SSH 用户名 / SSH 私钥配置进 GitHub 仓库 Settings -> Secrets and variables -> Actions"
echo "3. 回到 GitHub 仓库,手动触发一次 'Deploy 1000h-portal (Docker to AWS)' workflow,完成首次部署"
