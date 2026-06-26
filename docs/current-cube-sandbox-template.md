# 当前 Cube Sandbox 模板信息

本文记录当前已经创建并验证通过的 Cube sandbox 模板，供后续配置、排查和复用。

## 模板概览

```bash
export CUBE_TEMPLATE_ID="tpl-730a9b20700844168eb10a59"
```

| 项目 | 值 |
|---|---|
| Template ID | `tpl-730a9b20700844168eb10a59` |
| 状态 | `READY` |
| 类型 | `cubebox` |
| 版本 | `v2` |
| 源镜像 | `cube-leagent-template:cube-ready` |
| Build Job ID | `11fc7993-f55d-4eed-91b8-fb9ccf2f6234` |
| Artifact ID | `rfs-9816462436ff47adafce8e2e` |
| RootFS SHA256 | `a454157ea4e2e73b7bdffb6177938ff0389fe4ee2e54cf9fec5bbae3054ac179` |
| Template fingerprint | `9816462436ff47adafce8e2e444164d889ce374b268ad7b89217eb5accc9ae09` |
| 可写层 | `10G` |
| CPU / 内存 | `2000m` / `2000Mi` |
| 工作目录 | `/workspace` |
| 网络类型 | `tap` |
| 节点 | `10.110.158.143` |

## 暴露端口

模板暴露的端口为：

```text
5901:6080:9223
```

含义：

| 端口 | 用途 |
|---|---|
| `5901` | VNC |
| `6080` | noVNC Web 访问 |
| `9223` | Chromium CDP |
| `49999` | Code Interpreter API，健康检查端口 |
| `49983` | envd，基础镜像提供 |

注意：`49999` 用作健康检查和代码执行 API，不在 `com.exposed_ports` 中显示，但模板启动后可用。

## 启动命令

Cube 模板实际启动命令：

```bash
/bin/bash -lc '/etc/cont-init.d/99-browser-vnc || true; exec /root/.jupyter/start-up.sh'
```

含义：

1. 先执行 `/etc/cont-init.d/99-browser-vnc`，启动 VNC / noVNC / Xvfb / Chromium 可视化栈。
2. 即使 VNC 初始化脚本返回非 0，也继续启动主服务。
3. `exec /root/.jupyter/start-up.sh` 启动基础镜像自带的 envd、Jupyter、Code Interpreter API。

## 环境变量

模板创建时显式注入的环境变量：

```bash
DISPLAY=:0
SCREEN_GEOM=1920x1080x24
RESOLUTION=1920x1080x24
RESOLUTION_WIDTH=1920
RESOLUTION_HEIGHT=1080
VNC_PORT=5901
NOVNC_PORT=6080
```

这些变量保证 VNC 桌面分辨率、noVNC 端口和显示环境一致。

## 镜像准备说明

该模板使用的镜像是：

```bash
cube-leagent-template:cube-ready
```

它是在原始镜像基础上补了一层 Cube 兼容修改：

```bash
cube-leagent-template:local -> cube-leagent-template:cube-ready
```

关键改动：

- 新增 `/usr/local/bin/cube-start.sh`。
- 新增 `/usr/local/bin/pi` 软链接，指向 `/home/user/.npm-global/bin/pi`。
- 新增 `/usr/local/bin/pi-mcp-adapter` 软链接。
- 设置镜像默认 `ENTRYPOINT` 为 `/usr/local/bin/cube-start.sh`。
- 设置镜像默认 `WORKDIR` 为 `/workspace`。

即便镜像本身已有 `ENTRYPOINT`，模板创建时仍显式覆盖了启动命令，这是当前验证通过的稳定方式。

## 创建模板时使用的命令

以下是本模板创建时使用的核心命令，可作为复现参考：

```bash
/usr/local/services/cubetoolbox/CubeMaster/bin/cubemastercli template create-from-image \
  --image cube-leagent-template:cube-ready \
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
  --json
```

构建完成时的 Job 信息：

```text
job_id:     11fc7993-f55d-4eed-91b8-fb9ccf2f6234
template_id: tpl-730a9b20700844168eb10a59
artifact_id: rfs-9816462436ff47adafce8e2e
status:     READY
```

## 验证结果

已使用该模板创建测试沙箱，并验证以下项目通过：

| 检查项 | 结果 |
|---|---|
| 创建 sandbox | 通过 |
| `49999/health` | `200` |
| noVNC `/` | `200` |
| `/workspace` | 存在 |
| `/workspace/uploads` | 存在 |
| `/workspace/browser-shots` | 存在 |
| `chromium` | `/usr/bin/chromium` |
| `rg` | `/usr/bin/rg` |
| `pi` | `/usr/local/bin/pi` |
| `49999` 端口 | 监听 |
| `5901` 端口 | 监听 |
| `6080` 端口 | 监听 |

测试用沙箱已经删除。

## 业务配置方式

如果要让业务系统使用这个模板，设置：

```bash
CUBE_TEMPLATE_ID=tpl-730a9b20700844168eb10a59
```

临时 shell 中使用：

```bash
export CUBE_TEMPLATE_ID="tpl-730a9b20700844168eb10a59"
```

写入 `.env` 时，建议替换旧值，不要重复追加多行：

```bash
# 示例：手动编辑 backend/.env
CUBE_TEMPLATE_ID=tpl-730a9b20700844168eb10a59
```

## 查询命令

查看当前模板详情：

```bash
curl -sS http://127.0.0.1:3000/templates/tpl-730a9b20700844168eb10a59 | python3 -m json.tool
```

查看 CubeMaster 侧模板信息：

```bash
/usr/local/services/cubetoolbox/CubeMaster/bin/cubemastercli template info \
  --template-id tpl-730a9b20700844168eb10a59
```

列出所有模板：

```bash
curl -sS http://127.0.0.1:3000/templates | python3 -m json.tool
```
