# scripts 目录脚本说明

该目录包含构建 Docker 镜像、启动本地容器、创建 Cube 模板/沙箱，以及在容器或沙箱中初始化 VNC、Pi 和 Multica 运行时的辅助脚本。

## 推荐使用流程

1. `build.sh`：从 Multica 仓库编译二进制，并构建本项目 Docker 镜像。
2. `run.sh`：本地启动构建好的 Docker 容器，暴露 noVNC、VNC 和 Code API 端口，用于调试。
3. `diagnose.sh`：检查本地运行容器中的端口、进程、s6 服务注册和关键路径。
4. `create-cube-template.sh`：把本地 Docker 镜像转换为 Cube sandbox template。
5. `create-runtime-sandbox.sh`：基于 Cube template 创建实际 sandbox，并注入运行时密钥与 Multica 配置。

## 脚本用途一览

| 脚本 | 用途 |
| --- | --- |
| `build.sh` | 构建 Docker 镜像。会先在宿主机从 GitHub Releases 下载 `multica` 到 `multica/bin/multica`，再 `COPY` 进镜像。可用 `MULTICA_SKIP_DOWNLOAD=1` 复用已下载文件，或 `MULTICA_LOCAL_BIN=...` 指定本地二进制。支持通过环境变量控制镜像 tag、基础 sandbox 镜像、Pi 安装版本等。 |
| `run.sh` | 本地启动容器进行调试。会加载 `config/pi.env`，清理旧容器，映射 `6080` noVNC、`5901` VNC、`49983/49999` API 端口，并传入 `TEAM_*`、`MULTICA_*` 等运行时环境变量。启动后会尝试确保 VNC 栈和 Multica daemon 已运行。 |
| `diagnose.sh` | 诊断本地容器状态。输出容器信息、端口映射、VNC/noVNC/Xvfb 相关进程、监听端口、关键路径、s6 服务注册情况，并用 `curl` 检查本机端口可达性。 |
| `create-cube-template.sh` | 将本项目构建出的 Docker 镜像注册成 Cube sandbox template。会检查镜像内是否包含 Cube、VNC、Pi、Multica 运行时脚本，调用 `cubemastercli template create-from-image` 创建模板，并把 `CUBE_TEMPLATE_ID` 等结果写入 `.cube-template.env`。 |
| `create-runtime-sandbox.sh` | 创建 Cube sandbox 并注入运行时配置。会读取 `config/pi.env` 或当前环境变量，调用 Cube API 创建 sandbox，然后通过 sandbox 的 `/execute` 接口执行 `start-multica-runtime.sh`，动态配置 Pi 和 Multica 并启动 daemon。 |
| `cube-start.sh` | Cube sandbox 的主入口脚本。设置 PATH、DISPLAY、分辨率和 VNC/noVNC 端口，先启动浏览器/VNC 初始化脚本，再执行基础 Code API 启动脚本 `/root/.jupyter/start-up.sh`。 |
| `cont-init-browser.sh` | VNC 栈的兜底启动脚本。如果没有检测到 `entrypoint-vnc.sh` 正在运行，会以 `user` 用户启动 `/entrypoint-vnc.sh`，用于 sandbox-code 没有自动拉起 VNC 服务的场景。 |
| `entrypoint-vnc.sh` | 启动图形桌面和远程浏览器访问能力。负责启动 `Xvfb`、`openbox`、`x11vnc`、`websockify/noVNC`，可选自动打开 Chromium，并按分辨率调整浏览器窗口。 |
| `register-s6-services.sh` | 在镜像构建或初始化阶段注册 s6 服务。把 `playwright-vnc` 和 `multica-daemon` 加入 s6 user bundle，并把注册结果写到 `/etc/s6-overlay/playwright-vnc-registration.log`。 |
| `configure-pi-runtime.sh` | 根据运行时环境变量写入 Pi 配置。主要更新用户目录下 `.pi/agent/models.json` 和 `settings.json`，设置 OpenAI 兼容 provider 的 `baseUrl`、`apiKey`、默认模型和主题。 |
| `configure-multica-runtime.sh` | 根据运行时环境变量写入 Multica CLI/daemon 配置。需要 `MULTICA_SERVER_URL`、`MULTICA_APP_URL`、`MULTICA_WORKSPACE_ID`、`MULTICA_TOKEN`，会写入默认 profile 或指定 `MULTICA_PROFILE` 的 `config.json`。 |
| `entrypoint-multica-daemon.sh` | Multica daemon 的前台入口。会先配置 Pi 和 Multica，如果配置完整则执行 `multica daemon start --foreground`；如果 `MULTICA_DAEMON_ENABLED!=1` 或配置缺失，则保持容器进程不退出。 |
| `start-multica-runtime.sh` | 在已经创建的 sandbox/container 中动态配置并启动 Multica daemon。必要时切换到 `user` 用户执行，写入 Pi/Multica 配置，停止旧 daemon，然后后台启动 `/entrypoint-multica-daemon.sh` 并记录日志。 |

## 常用环境变量

| 变量 | 说明 |
| --- | --- |
| `TAG` | `build.sh` 生成的 Docker 镜像 tag，默认 `cube-leagent-template:local`。 |
| `IMAGE` | `run.sh` / `diagnose.sh` 使用的本地镜像名，默认 `cube-leagent-template:local`。 |
| `PI_CONFIG` | 运行时配置文件路径，默认 `config/pi.env`。 |
| `TEAM_API_KEY` | Pi/OpenAI 兼容 provider 的 API Key。 |
| `TEAM_BASE_URL` | Pi/OpenAI 兼容 provider 的 Base URL。 |
| `TEAM_MODEL` | Pi 默认模型名。 |
| `MULTICA_SERVER_URL` | Multica 后端服务地址。 |
| `MULTICA_APP_URL` | Multica Web/App 地址。 |
| `MULTICA_WORKSPACE_ID` | Multica workspace ID。 |
| `MULTICA_TOKEN` | Multica 认证 token。 |
| `MULTICA_PROFILE` | 可选；指定 Multica profile，配置会写入 `~/.multica/profiles/<profile>/config.json`。 |
| `MULTICA_DAEMON_ENABLED` | 是否启动 Multica daemon，默认 `1`。 |
| `CUBE_TEMPLATE_ID` | `create-runtime-sandbox.sh` 使用的 Cube template ID。 |
| `CUBE_API_URL` | Cube API 地址，默认 `http://127.0.0.1:3000`。 |
| `CUBE_PROXY_HTTP` | Cube sandbox execute 代理入口，默认 `http://127.0.0.1`。 |

## 注意事项

- `TEAM_*` 和 `MULTICA_*` 这类密钥/账号配置不会写入 Docker 镜像层，应该在运行容器或创建 sandbox 时通过环境变量注入。
- `configure-multica-runtime.sh` 在缺少必需的 `MULTICA_*` 变量时会返回 `2`，不会写入配置文件。
- 镜像内的 `multica` 由 `build.sh` 在宿主机下载后拷贝进镜像，Docker build 阶段不再直连 GitHub。
- `MULTICA_SKIP_DOWNLOAD=1` 可跳过下载并复用 `multica/bin/multica`；`MULTICA_LOCAL_BIN` 可指定已有二进制。
- `run.sh` 会删除同镜像的旧容器以及同名容器，适合本地调试使用，生产环境谨慎执行。
