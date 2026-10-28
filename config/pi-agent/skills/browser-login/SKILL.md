---
name: browser-login
description: Log in, register, or operate websites on this CoForge cloud computer using Chromium, CDP, or Playwright. Use when the user asks to open a site, sign in, sign up, fill forms, click through a web UI, or when you would otherwise say you cannot use a browser.
---

# 云电脑浏览器登录 / 注册

本机有图形桌面、系统 Chromium，以及**已预装**的 Python Playwright 包。网站登录、注册、填表是常规能力。不要回答「我无法打开网页 / 无法登录」。

## 不要做的事

- **不要** `pip install playwright`（镜像已装）
- **不要** `playwright install` / `playwright install chromium`（使用系统 `/usr/bin/chromium`，不要再下浏览器）
- import 失败时先 `python3 -c "from playwright.sync_api import sync_playwright"` 自检，再决定是否安装

## 执行前

```bash
echo "DISPLAY=${DISPLAY:-unset}"
command -v chromium coforge-chromium python3
python3 -c "from playwright.sync_api import sync_playwright; print('playwright ok')"
mkdir -p /workspace/browser-shots
```

- 若 `DISPLAY` 未设置：尝试 `export DISPLAY=:0`，再复查。
- 仍无显示/无 chromium：简要说明探测结果，再给替代方案。不要空拒绝。

## 推荐路径（按优先级）

### A. 桌面 Chromium（适合登录、注册、需要真人可见的流程）

CDP 端口规则与 `coforge-chromium` 一致：`9222 + 显示号`（`:0` → `9222`，`:1` → `9223`）。

```bash
# 后台打开站点（示例）
DISPLAY="${DISPLAY:-:0}" nohup coforge-chromium --new-window "https://EXAMPLE/" \
  >/tmp/coforge-chromium.log 2>&1 &

# 确认 CDP
display_num="${DISPLAY#:}"; display_num="${display_num%%.*}"
port=$((9222 + ${display_num:-0}))
curl -sf "http://127.0.0.1:${port}/json/list" | head
```

然后：

1. 用 Playwright `connect_over_cdp` 连已有 CDP，或继续在页面上操作。
2. 需要账号密码时向用户索取；验证码/二次验证让用户看 noVNC（`:6080`）或你贴截图后协助输入。
3. 关键关键截图到 `/workspace/browser-shots/`，确认是否已登录成功。

### B. Playwright 直连（适合可脚本化的表单）

必须指定系统 Chromium，不要依赖 Playwright 自带浏览器：

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    # 有 DISPLAY 时用有头，便于 VNC 观察
    browser = p.chromium.launch(
        headless=False,
        executable_path="/usr/bin/chromium",
        args=["--no-sandbox", "--disable-dev-shm-usage"],
    )
    page = browser.new_page()
    page.goto("https://EXAMPLE/")
    # page.fill(...) / page.click(...) / page.screenshot(path="/workspace/browser-shots/step.png")
    browser.close()
```

也可用 `connect_over_cdp(f"http://127.0.0.1:{port}")` 附着到已打开的 `coforge-chromium`。

### C. 已打开页面上的敏感填表

`/usr/local/bin/page-fill.py` 通过 CDP 填字段且避免把密文打进日志；它主要由桌面/VNC 服务调用。Agent 侧优先用 Playwright 的 `fill`，密码不要写进 shell 历史或世界可读文件。

## 操作清单

1. 打开目标 URL（Chromium 或 Playwright）。
2. 识别登录/注册入口并进入表单。
3. 缺凭证就问用户；有凭证就填写并提交。
4. 处理同意条款、验证码、邮件/短信码（需要用户提供或在 VNC 中完成）。
5. 用截图或 DOM 检查确认成功（出现头像、仪表盘、退出按钮等）。
6. 把结果（成功/卡在哪一步/需要什么）简短回报用户。

## 硬规则

- 未做上述探测前，禁止说没有浏览器或无法登录。
- 不要把完整密码回显到聊天或写入世界可读日志。
- 失败时说明已尝试的步骤与当前页面状态，而不是直接放弃。
