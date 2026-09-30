# dsh-deep-whale 桌面端（DSH Desktop / Electron）部署说明

本文件记录把 dsh-deep-whale 皮肤部署到 **DSH 桌面应用**时实测到的机制，以及正确的安装路径。
结论来自对已安装桌面端 `app.asar` 与其 profile 的实际读取，不是推测。

> 文中 `<DSH>` 表示 DSH 桌面端安装目录（即包含 `DeepSeek Harness.exe` 的目录，
> 常见为 `%LOCALAPPDATA%\Programs\DeepSeek Harness`），`<repo>` 表示本仓库目录。
> `19387`、`0.2.0-rc.2` 等为实测值，随版本可能变化。

## 一、桌面端和网页端是什么关系

| 项 | 网页端 | 桌面端 |
|---|---|---|
| 启动方式 | `dsh web` / `npx dsh web` | `<DSH>\DeepSeek Harness.exe` |
| profile | `~/.dsh/profiles/web` | `~/.dsh/profiles/desktop` |
| bundle 层 | `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app` | 同上 |
| 客户端渲染 | 浏览器 + Web 前端 | Electron(Chromium) + **同一套 Web 前端** |
| 服务端口 | 3080（默认） | 19387（`dsh-desktop-host` 硬编码） |
| DSH 版本 | `@deepseek-ai/dsh` 0.2.0-rc.2 | 0.2.0-rc.2（同一版本） |

关键证据：`@deepseek-ai/dsh-desktop-host/lib/index.js` 的 `main()` 调用
`runProfile({ profile: "desktop", args: ["--no-open", "--port", "19387"] })`，
即桌面端就是「以 `desktop` profile 运行的同一个 Web 应用」，另加 Office / 更新 / 退出检查等桌面插件。

## 二、平台标识只有 "web"，皮肤无需改代码

宿主侧客户端插件解析器 `@deepseek-ai/dsh-client-modules/lib/index.js`：

```js
if (decl === void 0 || decl.platform !== "web") { this.pkgMeta.set(sourceKey, null); return null }
```

`dsh-client-modules/README.md` 也明确：「A browser plugin package declares `dsh.client` in its
`package.json` with `platform: 'web'`」。桌面端共用这个解析器，**不存在 "desktop" 平台取值**。

因此皮肤 `package.json` 里的：

```json
"dsh": { "client": { "platform": "web" } }
```

对桌面端本来就是正确的。所谓「改成桌面端」实质是**装进 `desktop` profile**，而不是改平台字段或重建 bundle。

## 三、desktop profile 不能用普通 dsh CLI 管理

`@deepseek-ai/dsh/lib/bin.js`：

```js
// 启动 / --dump-config 路径，无条件拒绝
rejectElectronProfile(program, profile)   // profile === "desktop" -> error
// plugin 子命令，允许桌面端载体解除限制
if (!manageDesktopProfile) rejectElectronProfile(plugin, options.profile)
```

- 直接跑 `dsh plugin --profile desktop add ...` 会报
  `error: profile "desktop" is managed exclusively by the Electron application`；
- **桌面端自带 CLI** 会传 `manageDesktopProfile: true`，因此可用：

```powershell
& "<DSH>\resources\runtime\cli\bin\dsh.cmd" plugin --profile desktop add <绝对路径>
```

该 CLI 的内容等价于：

```bat
set ELECTRON_RUN_AS_NODE=1
"…\DeepSeek Harness.exe" --expose-internals "…\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js" %*
```

它使用应用自带的 pnpm（`resources\runtime\pnpm\bin\pnpm.mjs`，实测 v11.7.0）在 profile 目录内安装。
`plugin add` 成功后会自动把包名写进 profile `package.json` 的 `dsh.profile.bundles`。

**边界**：即使走这个 CLI，**启动桌面 profile 和 `--dump-config` 依旧被禁止**，配置组合验证只能靠应用自身。
新增/删除插件包后需要**完全退出并重开桌面应用**才会加载（配置热重载只对已加载的插件生效）。

## 四、标准部署步骤

一键脚本（本仓库根目录）：`install-desktop-skins.ps1`

```powershell
pwsh -File .\install-desktop-skins.ps1 -Target maid-atelier
# 桌面端不在常见位置时：
pwsh -File .\install-desktop-skins.ps1 -AppRoot "D:\DSH" -Target orca-link
```

脚本做的事与网页端流程一致，只是把 CLI 换成桌面端自带 CLI：

1. 自动探测桌面端安装目录并定位其自带 CLI；
2. 扫描仓库内 `skin.json`（实时，不硬编码）；
3. `stage-mutual-exclusion.mjs --profile desktop --target <皮肤|official>`
   —— 在两个 patch 层写入互斥 `disabled` 行，**必须发生在任何 plugin add 之前**，
   只写 `# --- dsh-skin managed ---` 托管块，保留 profile patch 里既有的 ui-chat / ui-settings 配置；
4. `dsh.cmd plugin --profile desktop add <绝对路径>` 依次注册 skin-manager 与全部皮肤；
5. 校验依赖清单与 `dsh.profile.bundles`；
6. 提示用户重启桌面应用。

手工等价命令：

```powershell
node <repo>\.agents\skills\dsh-skin-install\scripts\stage-mutual-exclusion.mjs --profile desktop --target maid-atelier
$cli = "<DSH>\resources\runtime\cli\bin\dsh.cmd"
& $cli plugin --profile desktop add <repo>\skin-manager
& $cli plugin --profile desktop add <repo>\maid-atelier
& $cli plugin --profile desktop add <repo>\orca-link
```

## 五、互斥的两个 patch 层

| 层 | 路径 | 作用范围 |
|---|---|---|
| profile 层 | `~/.dsh/profiles/desktop/cordis.patch.yml` | 仅桌面端 |
| home 层 | `~/.dsh/cordis.patch.yml` | **所有 profile 共用**（网页端 + 桌面端） |

home 层是共用的，因此同一台机器上网页端与桌面端会共享同一份皮肤启停状态；
切换皮肤时两个层都要写（脚本/管理器已自动处理）。

## 六、已知注意事项

- 皮肤包的安装位置用绝对路径；裸目录名会被当作 npm 包名去 registry 拉取并 404。
- 重新 `add` 同一 clone 的包是幂等的；移动 clone 目录后必须用新绝对路径重新 add。
- 桌面端菜单提供「禁用第三方插件、备份 profile patch 并重启」的恢复入口：
  万一皮肤导致界面异常，可用它一键回到干净状态。
- 皮肤在桌面端与网页端共用同一渲染栈，视觉表现一致；桌面窗口自带的标题栏/窗口按钮区域
  若与皮肤装饰层重叠，属于观感问题，可在皮肤 CSS 内针对桌面窗口做局部适配。

## 七、相关：`tapIndex` 与注入行（改桌面端插件时会踩的坑）

DSH 的 index 注入分两层（`@deepseek-ai/dsh-host-webserver/README.zh.md`）：

1. **结构化注入行**：`collectIndexInjections()` 每次发一次 `webserver/index-inject` 事件，
   订阅方推入自己的行（`kind`：`global` / `script` / `script-src` / `script-preload` / `style` / `html`）；
2. **原始 `tapIndex` 转换**：`renderIndex(html)` 渲染完行之后再按注册顺序应用。

差别在"静态部署"（桌面端）：

- 网页端 index.html 由宿主现场渲染 → 两层都生效；
- 桌面端 index.html 是 `dsh-web-frontend/dist` 的静态文件，由 Electron 主进程直接返回，
  宿主只把 `collectIndexInjections()` 的**行**塞进 `dsh-desktop:boot` 的 payload，
  渲染器只按 `kind` 应用这些行，**从不执行 `tapIndex` 转换**。

因此：**只靠 `tapIndex` 注入前端脚本的插件，在桌面端会静默失效**（无报错、无日志），
必须改用结构化注入行；注意 `html` 行走 `insertAdjacentHTML`，按规范其中的 `<script>` 不执行，
要加载外部脚本请用 `script` 或 `script-src` 行。
