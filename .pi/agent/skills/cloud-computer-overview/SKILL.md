---
name: cloud-computer-overview
description: Map CoForge/Cube cloud-computer resources (shell, /workspace, Chromium, VNC/noVNC, CDP, Playwright, common ports). Use when unsure what tools exist, before refusing a task, or when exploring how to solve a new request on this machine.
---

# 云电脑资源地图

你在 CoForge / Cube 云电脑里。先用本 skill 搞清「有什么、怎么用」，再动手；不要凭通用聊天助手的先验说做不到。

## 快速自检

```bash
echo "DISPLAY=$DISPLAY USER=$(id -un) PWD=$PWD"
command -v chromium coforge-chromium python3 node npm rg fd pi
python3 -c "from playwright.sync_api import sync_playwright; print('playwright ok')"
ls -la /workspace /workspace/uploads /workspace/browser-shots 2>/dev/null || true
ss -ltn 2>/dev/null | grep -E ':(5901|6080|9222|9223|49999)\b' || netstat -ltn 2>/dev/null | grep -E ':(5901|6080|9222|9223)\b' || true
```

## 资源一览

| 资源 | 位置 / 端口 | 用途 |
|---|---|---|
| 工作区 | `/workspace` | 代码与任务文件 |
| 上传 | `/workspace/uploads` | 用户上传 |
| 截图 | `/workspace/browser-shots` | 浏览器/桌面截图落盘 |
| 显示 | `DISPLAY`（常见 `:0`） | X11 桌面 |
| Chromium | `chromium` / `coforge-chromium` | GUI 浏览；CDP 端口 = `9222 + 显示号`（`:0`→9222，`:1`→9223） |
| VNC | `:5901` | 原生 VNC |
| noVNC | `:6080` | 浏览器看桌面 |
| Playwright | 镜像已预装 `playwright` Python 包 | 连系统 Chromium / CDP；勿再 `pip install` 或 `playwright install` |
| 填表辅助 | `/usr/local/bin/page-fill.py` | 经 CDP 向已打开页面填字段（多为桌面服务调用） |

## 选型指引

1. **命令行能完成**（文件、包、API、git）→ 直接 shell。
2. **需要登录/注册/点网页** → 读并遵循 `browser-login` skill；默认用 Chromium 或 Playwright，不要推回用户。
3. **需要确认页面长什么样** → 截图到 `/workspace/browser-shots`，或提醒用户开 noVNC `:6080`。
4. **不确定** → 先自检 + `rg`/`ls` 找镜像内脚本与文档，再选路径；探测失败才说明限制。

## 探索顺序（新任务）

1. 读任务相关本地文档 / README。
2. `rg` 仓库与 `/usr/local` 是否已有脚本。
3. 跑上面的自检，确认桌面与浏览器是否可用。
4. 选最小可行路径执行；卡住再问用户要凭证或决策。
