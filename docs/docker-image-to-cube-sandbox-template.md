# 从 Docker 镜像制作 Cube Sandbox 模板

这份文档记录一套可手动复制执行的流程：把一个本地 Docker 镜像转换成 Cube sandbox template，并验证它能通过 E2B / Cube API 创建沙箱。

本文以当前机器上的镜像为例：

- 原始镜像：`cube-leagent-template:local`
- 最终用于 Cube 的镜像：`cube-leagent-template:cube-ready`
- 最终模板：`tpl-730a9b20700844168eb10a59`

如果你以后换了镜像，只需要改开头的变量即可。

## 0. 前置条件

确认 Cube 相关服务已经启动，并且本机能访问：

- CubeAPI：`http://127.0.0.1:3000`
- CubeMaster：`http://127.0.0.1:8089`
- CubeMaster CLI：`/usr/local/services/cubetoolbox/CubeMaster/bin/cubemastercli`

快速检查：

```bash
curl -sS http://127.0.0.1:3000/health
curl -sS http://127.0.0.1:8089/cube/template | head
/usr/local/services/cubetoolbox/CubeMaster/bin/cubemastercli template --help
```

正常情况下，`/health` 会返回类似：

```json
{"status":"ok","sandboxes":0}
```

## 1. 设置变量

后面的命令都依赖这些变量。以后换镜像时，优先只改这里。

```bash
export SOURCE_IMAGE="cube-leagent-template:local"
export CUBE_READY_IMAGE="cube-leagent-template:cube-ready"
export CUBEMASTER_CLI="/usr/local/services/cubetoolbox/CubeMaster/bin/cubemastercli"
export CUBE_API_URL="http://127.0.0.1:3000"
export CUBE_PROXY_HTTP="http://127.0.0.1"
```

确认镜像存在：

```bash
docker images | grep -E 'cube-leagent-template|REPOSITORY'
docker inspect "$SOURCE_IMAGE" --format 'ID={{.Id}} Entrypoint={{json .Config.Entrypoint}} Workdir={{.Config.WorkingDir}}'
```

## 2. 给镜像加一个 Cube 友好的启动脚本

为什么需要这一步：

- Cube 创建模板时，可能不会完全按你本地 `docker run` 的方式启动容器。
- 我们需要确保沙箱启动时同时启动：
  - Code Interpreter API：`49999`
  - envd：`49983`
  - VNC：`5901`
  - noVNC：`6080`
- 当前镜像里的 `pi` 安装在 `/home/user/.npm-global/bin/pi`，通过 API 执行代码时默认 `PATH` 可能找不到，所以这里额外做一个 `/usr/local/bin/pi` 软链接。

复制执行：

```bash
set -euo pipefail

NAME="cube-ready-patch"
docker rm -f "$NAME" >/dev/null 2>&1 || true

docker run --name "$NAME" --entrypoint /bin/sh "$SOURCE_IMAGE" -c '
set -eu

# 让 Cube API 执行环境也能找到 pi。
ln -sf /home/user/.npm-global/bin/pi /usr/local/bin/pi
ln -sf /home/user/.npm-global/bin/pi-mcp-adapter /usr/local/bin/pi-mcp-adapter || true

# Cube 沙箱启动脚本：先拉起 VNC/noVNC，再启动基础镜像自带的 envd + code interpreter + jupyter。
cat > /usr/local/bin/cube-start.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

export PATH="/home/user/.npm-global/bin:/home/user/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export DISPLAY="${DISPLAY:-:0}"
export SCREEN_GEOM="${SCREEN_GEOM:-1920x1080x24}"
export RESOLUTION="${RESOLUTION:-1920x1080x24}"
export RESOLUTION_WIDTH="${RESOLUTION_WIDTH:-1920}"
export RESOLUTION_HEIGHT="${RESOLUTION_HEIGHT:-1080}"
export VNC_PORT="${VNC_PORT:-5901}"
export NOVNC_PORT="${NOVNC_PORT:-6080}"

/etc/cont-init.d/99-browser-vnc || true
exec /root/.jupyter/start-up.sh
EOF
chmod +x /usr/local/bin/cube-start.sh
'

docker commit \
  --change 'USER root' \
  --change 'ENV PATH=/home/user/.npm-global/bin:/home/user/.bun/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin' \
  --change 'ENTRYPOINT ["/usr/local/bin/cube-start.sh"]' \
  --change 'WORKDIR /workspace' \
  "$NAME" "$CUBE_READY_IMAGE" >/dev/null

docker rm -f "$NAME" >/dev/null

docker inspect "$CUBE_READY_IMAGE" --format 'READY_IMAGE={{.Id}} ENTRYPOINT={{json .Config.Entrypoint}}'
```

## 3. 创建 Cube Template

注意：这里虽然镜像已经有 `ENTRYPOINT`，仍然建议显式传 `--cmd` 和 `--arg`。这是本机实际验证过的稳定写法。

```bash
set -euo pipefail

CREATE_OUTPUT=$("$CUBEMASTER_CLI" template create-from-image \
  --image "$CUBE_READY_IMAGE" \
  --writable-layer-size 10G \
  --expose-port 5901 \
  --expose-port 6080 \
  --expose-port 9223 \
  --probe 49999 \
  --probe-path /health \
  --cmd /bin/bash \
  --cmd -lc \
  --arg '/etc/cont-init.d/99-browser-vnc || true; exec /root/.jupyter/start-up.sh' \
  --env 'DISPLAY=:0' \
  --env 'SCREEN_GEOM=1920x1080x24' \
  --env 'RESOLUTION=1920x1080x24' \
  --env 'RESOLUTION_WIDTH=1920' \
  --env 'RESOLUTION_HEIGHT=1080' \
  --env 'VNC_PORT=5901' \
  --env 'NOVNC_PORT=6080' \
  --json)

echo "$CREATE_OUTPUT" | python3 -m json.tool
export CUBE_TEMPLATE_JOB_ID=$(printf '%s' "$CREATE_OUTPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["job_id"])')
export CUBE_TEMPLATE_ID=$(printf '%s' "$CREATE_OUTPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["template_id"])')

echo "CUBE_TEMPLATE_JOB_ID=$CUBE_TEMPLATE_JOB_ID"
echo "CUBE_TEMPLATE_ID=$CUBE_TEMPLATE_ID"
```

参数解释：

- `--image`：要转换成 Cube 模板的 Docker 镜像。
- `--writable-layer-size 10G`：沙箱运行时可写层大小。常用 `10G`。
- `--expose-port 5901`：VNC 端口。
- `--expose-port 6080`：noVNC 端口。
- `--expose-port 9223`：Chromium CDP 端口，供浏览器自动化使用。
- `--probe 49999 --probe-path /health`：Cube 用这个健康检查判断模板是否启动成功。
- `--cmd /bin/bash --cmd -lc --arg '...'`：覆盖启动命令，确保 VNC 栈和 code interpreter 都启动。

## 4. 等待 Template 构建完成

```bash
"$CUBEMASTER_CLI" template watch \
  --job-id "$CUBE_TEMPLATE_JOB_ID" \
  --interval 5s \
  --json
```

成功时会看到类似：

```text
template image job succeeded template_id=tpl-... job_id=... artifact_id=rfs-...
```

如果输出中 `status` 是 `READY`，模板就制作成功了。

也可以单独查看模板列表：

```bash
curl -sS "$CUBE_API_URL/templates" | python3 -m json.tool | head -80
```

查看某个模板详情：

```bash
curl -sS "$CUBE_API_URL/templates/$CUBE_TEMPLATE_ID" | python3 -m json.tool | head -160
```

## 5. 创建测试沙箱

```bash
set -euo pipefail

SANDBOX_OUTPUT=$(curl -sS --max-time 90 \
  -X POST "$CUBE_API_URL/sandboxes" \
  -H 'Content-Type: application/json' \
  -d "{\"templateID\":\"$CUBE_TEMPLATE_ID\",\"timeout\":600}")

echo "$SANDBOX_OUTPUT" | python3 -m json.tool
export CUBE_SANDBOX_ID=$(printf '%s' "$SANDBOX_OUTPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sandboxID"])')

echo "CUBE_SANDBOX_ID=$CUBE_SANDBOX_ID"
```

## 6. 运行烟雾测试

这个测试会检查：

- `/workspace` 目录是否存在
- `chromium` 是否可用
- `rg` 是否可用
- `pi` 是否可用
- `49999`、`5901`、`6080` 是否监听

```bash
set -euo pipefail

cat > /tmp/cube-smoke.json <<'JSON'
{
  "code": "import os, socket, shutil, json\ndef up(p):\n    s = socket.socket(); ok = s.connect_ex(('127.0.0.1', p)) == 0; s.close(); return ok\nchecks = {\n  'cwd': os.getcwd(),\n  'workspace': os.path.isdir('/workspace'),\n  'uploads': os.path.isdir('/workspace/uploads'),\n  'browser_shots': os.path.isdir('/workspace/browser-shots'),\n  'display': os.environ.get('DISPLAY'),\n  'path': os.environ.get('PATH'),\n  'chromium': shutil.which('chromium'),\n  'rg': shutil.which('rg'),\n  'pi': shutil.which('pi'),\n  'port_49999': up(49999),\n  'port_5901': up(5901),\n  'port_6080': up(6080),\n}\nprint(json.dumps(checks, ensure_ascii=False, sort_keys=True))",
  "language": "python"
}
JSON

curl -i -sS --max-time 60 \
  -H "Host: 49999-${CUBE_SANDBOX_ID}.cube.app" \
  -H 'Content-Type: application/json' \
  --data @/tmp/cube-smoke.json \
  "$CUBE_PROXY_HTTP/execute"
```

成功输出中应该能看到类似：

```json
{
  "browser_shots": true,
  "chromium": "/usr/bin/chromium",
  "display": ":0",
  "pi": "/usr/local/bin/pi",
  "port_49999": true,
  "port_5901": true,
  "port_6080": true,
  "rg": "/usr/bin/rg",
  "uploads": true,
  "workspace": true
}
```

再检查 noVNC 和 code API：

```bash
curl -sS -o /dev/null -w 'noVNC / => %{http_code}\n' \
  --max-time 10 \
  -H "Host: 6080-${CUBE_SANDBOX_ID}.cube.app" \
  "$CUBE_PROXY_HTTP/"

curl -sS -o /dev/null -w 'code /health => %{http_code}\n' \
  --max-time 10 \
  -H "Host: 49999-${CUBE_SANDBOX_ID}.cube.app" \
  "$CUBE_PROXY_HTTP/health"
```

两个都应该返回 `200`。

## 7. 删除测试沙箱

测试完成后删除临时沙箱，避免占资源：

```bash
curl -i -sS --max-time 30 \
  -X DELETE "$CUBE_API_URL/sandboxes/$CUBE_SANDBOX_ID"
```

成功时返回：

```text
HTTP/1.1 204 No Content
```

## 8. 在业务系统中使用模板

把模板 ID 写到业务系统环境变量里，例如：

```bash
export CUBE_TEMPLATE_ID="$CUBE_TEMPLATE_ID"
echo "CUBE_TEMPLATE_ID=$CUBE_TEMPLATE_ID"
```

如果要写入 `.env`，示例：

```bash
printf '\nCUBE_TEMPLATE_ID=%s\n' "$CUBE_TEMPLATE_ID" >> backend/.env
```

如果已有旧值，建议手动编辑替换，避免重复。

## 9. 本次实际产物

本机这次已经做好的可用模板：

```bash
export CUBE_TEMPLATE_ID="tpl-730a9b20700844168eb10a59"
```

对应信息：

```text
Source image: cube-leagent-template:cube-ready
Template ID:  tpl-730a9b20700844168eb10a59
Build job:    11fc7993-f55d-4eed-91b8-fb9ccf2f6234
Artifact:     rfs-9816462436ff47adafce8e2e
Status:       READY
```

## 10. 常见问题

### 问题 1：创建模板时提示 `source_image_ref is required`

通常是调用了 CubeAPI 的 `POST /templates`，但请求体格式不对。推荐直接使用：

```bash
"$CUBEMASTER_CLI" template create-from-image --image "$CUBE_READY_IMAGE" ...
```

### 问题 2：模板构建失败，提示 `49999/health connection refused`

说明启动命令没有正确拉起 code interpreter。用本文第 3 步的 `--cmd /bin/bash --cmd -lc --arg '...'` 写法。

关键命令是：

```bash
--cmd /bin/bash \
--cmd -lc \
--arg '/etc/cont-init.d/99-browser-vnc || true; exec /root/.jupyter/start-up.sh'
```

### 问题 3：沙箱里 noVNC 不通，`6080` 不是 200

先确认模板创建时暴露了端口：

```bash
--expose-port 5901 \
--expose-port 6080 \
--expose-port 9223
```

再用 smoke test 检查 `port_5901` 和 `port_6080` 是否为 `true`。

### 问题 4：沙箱里 `pi` 找不到

确认第 2 步里做了软链接：

```bash
ln -sf /home/user/.npm-global/bin/pi /usr/local/bin/pi
```

也可以进入一个本地容器检查：

```bash
docker run --rm --entrypoint /bin/sh "$CUBE_READY_IMAGE" -lc 'command -v pi; ls -l /usr/local/bin/pi'
```

### 问题 5：想删除失败或不用的模板

谨慎操作，确认模板 ID 后再删：

```bash
"$CUBEMASTER_CLI" template delete --template-id tpl-xxxxx
```

删除前建议先看详情：

```bash
"$CUBEMASTER_CLI" template info --template-id tpl-xxxxx
```
