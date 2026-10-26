# GKI 内核构建：SukiSU Ultra + android14-6.1.138

个人专用的内核构建仓库，在 GitHub Actions 上构建一个目标：

| 项目 | 内容 |
|:---|:---|
| 内核 | GKI `android14-6.1`，6.1.138（`2025-06` 安全补丁） |
| Root | [SukiSU Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)（开 SUSFS 用 `builtin` 分支，否则用 `main`） |
| 默认开启 | SUSFS、KPM、ZRAM 增强（lz4k / lz4kd）、BBG 防格机、CVE-2026-43499 rtmutex 修复 |

## 怎么构建

**手动**：Actions → `构建内核 (SukiSU Ultra / android14-6.1.138)` → Run workflow。
上面几项功能都可以单独关掉；`release` 勾上会在构建成功后发 GitHub Release，不勾就只留 artifacts（保留 14 天）。

**自动**：`auto-trigger.yml` 每天 UTC 03:17 检查一次 SukiSU（`builtin` 分支）和
[ShirkNeko/susfs4ksu](https://github.com/ShirkNeko/susfs4ksu)（`gki-android14-6.1` 分支），有新提交就用默认参数触发构建并发布 Release。
上次看到的提交记录在 `sha` 分支的 `latest_sha.txt` 里。

- 自动触发的构建失败了**不会重试**，要等上游下一次更新，或者手动再跑一次。
- GitHub 会在仓库 60 天没有活动后停用定时任务；如果发现自动构建不跑了，到 Actions 页面重新启用，或手动跑一次。
- 想强制跑一次自动流程：手动运行 `上游更新自动构建`，勾选 `force`。

## 产物

Release（或 Actions artifacts）里有：

- `*-AnyKernel3.zip`：用 recovery / Kernel Flasher 刷入
- `*-boot*.img`：已签名的 boot 镜像（raw / gz / lz4 三种压缩）
- SukiSU 管理器 APK、SUSFS 配套模块

刷机前先确认手机当前内核是 `6.1.x-android14`（`uname -r`），并备份原厂 boot。

## 换内核版本

改 `.github/workflows/build.yml` 顶部 `env` 里的四行，让它们互相对应：

```yaml
ANDROID_VERSION: android14
KERNEL_VERSION: "6.1"
SUB_LEVEL: "138"
OS_PATCH_LEVEL: "2025-06"   # 子版本号与补丁月份的对应关系见 Google 的 GKI 发布说明
```

构建日志里会打印同步下来的实际子版本号，和 `SUB_LEVEL` 不一致时会给出警告。
只改 6.1 小版本是安全的；换成别的内核大版本（5.10 / 5.15 / 6.6 / 6.12）需要补回对应的 SUSFS、ZRAM、CVE 补丁逻辑，这个仓库已经删掉了。

## 固定上游提交

最新提交把构建搞坏时，编辑 `config/config`：`custom=true`，填上 `sukisu=` 和 / 或 `gki-android14-6.1=` 的提交哈希。

## 目录

```
.github/workflows/
  build.yml          构建 + 发布（手动触发入口）
  get-manager.yml    下载 SukiSU 管理器和 SUSFS 模块，计算版本号
  auto-trigger.yml   上游有更新就触发 build.yml
config/              固定提交配置、伪装用的 stock config、ZRAM 配置片段
scripts/susfs_fixes/ SUSFS 补丁的上下文修复
security_patch/      CVE-2026-43499 rtmutex 修复
zram/                LZ4 升级补丁
```

## 许可

见 [LICENSE](LICENSE)。
