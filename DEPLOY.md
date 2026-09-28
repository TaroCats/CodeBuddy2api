# 自动化部署指南（CI 构建镜像 / 上游同步 / 容器自动更新）

本文只讲这个 fork 新增的自动化能力，接口用法请看 [README.md](./README.md) 和 [USAGE.md](./USAGE.md)。

> 上游仓库是 **[Sliverkiss/CodeBuddy2api](https://github.com/Sliverkiss/CodeBuddy2api)**。
> README 里出现的 `xueyue33/codebuddy2api` 是更早的原作者仓库，不要把它当成同步源。

## 整体流程

```
   上游 Sliverkiss/CodeBuddy2api
              │  ① 每 6 小时检查一次（也可手动触发）
              ▼
   sync-upstream.yml ── 有新提交？ ──否──▶ 结束
              │ 是
              ▼
        合并进本 fork main 并 push
              │  ②
              ▼
   build-image.yml ── 多架构构建 ──▶ ghcr.io/tarocats/codebuddy2api:latest
              │  ③
              ▼
        服务器 docker compose（watchtower 每 5 分钟检查一次）
              │  发现新镜像 → 自动拉取 → 重建容器
              ▼
              服务始终保持最新
```

新增的文件：

| 文件 | 作用 |
| --- | --- |
| `.github/workflows/build-image.yml` | 构建 Docker 镜像并推送到 GHCR |
| `.github/workflows/sync-upstream.yml` | 定时检测上游更新，有更新就合并并触发重新构建 |
| `.github/scripts/sync-upstream.sh` | 同步逻辑本体（也能在本地直接跑） |
| `docker-compose.ghcr.yml` | 用 GHCR 镜像部署，并内置 watchtower 自动更新 |
| `.env.example` / `.gitignore` / `.dockerignore` | 配置模板与忽略规则（防止密钥被提交 / 被打进镜像） |

---

## 一、首次启用（在 GitHub 上点几下）

1. **打开 Actions 写权限**
   `Settings → Actions → General → Workflow permissions` 选择 **Read and write permissions**，保存。
   （`sync-upstream.yml` 需要向 main 推送，`build-image.yml` 需要向 GHCR 推送。）

2. **允许创建/推送镜像包**
   同一个页面下方 `Workflow permissions` 已勾选 read/write 即可；无需额外配置。

3. **让镜像可以被匿名拉取（推荐）**
   第一次构建成功后，打开
   `https://github.com/users/TaroCats/packages/container/codebuddy2api/settings`
   → `Danger Zone` → `Change visibility` → **Public**。
   保持 Private 也能用，但服务器上必须先 `docker login ghcr.io`，见第五节。

4. **手动跑一次验证**
   `Actions → Sync Upstream & Rebuild Image → Run workflow`，
   勾选 `force_rebuild`，等待两个 job 变绿，镜像就上线了。

5. **（可选）改配置**
   `Settings → Secrets and variables → Actions → Variables`，可新建：

   | 变量名 | 默认值 | 说明 |
   | --- | --- | --- |
   | `UPSTREAM_REPO` | `Sliverkiss/CodeBuddy2api` | 上游仓库 |
   | `UPSTREAM_BRANCH` | `main` | 上游分支 |
   | `SYNC_CONFLICT_STRATEGY` | `theirs` | 冲突策略：`theirs` 上游优先 / `ours` 本地优先 / `fail` 直接报错 |
   | `PROTECTED_PATHS` | `.github` | 合并后强制保留本地版本的路径（空格分隔） |

   不改也能跑，全部有默认值。

---

## 二、镜像构建（build-image.yml）

**触发时机**

- push 到 `main`（只改 `*.md`、`LICENSE`、`.gitignore`、`.dockerignore` 时不重复构建）
- 打 `v*` 标签
- 手动 `Run workflow`
- 被 `sync-upstream.yml` 复用调用（同步到上游新代码后自动重建）

**产物标签**

| 触发 | 生成的标签 |
| --- | --- |
| push 到 main | `latest`、`main`、`sha-xxxxxxx` |
| 打 `v1.2.3` 标签 | `v1.2.3`、`sha-xxxxxxx` |

**默认构建 `linux/amd64` + `linux/arm64` 双架构**，Intel/AMD 服务器和 Apple Silicon、ARM NAS 都能直接用。
手动触发时可以把 `platforms` 改成 `linux/amd64` 加快速度。

镜像地址：

```
ghcr.io/tarocats/codebuddy2api:latest
```

> 如果你把仓库挪到别的账号，镜像名会自动跟着变（workflow 里取的是 `github.repository` 并转成小写），
> 记得同步修改 `docker-compose.ghcr.yml` 里的 `image:`。

---

## 三、上游同步（sync-upstream.yml）

默认**每 6 小时**（北京时间 02:23 / 08:23 / 14:23 / 20:23）检查一次上游：

- 上游没有新提交 → 直接结束，不产生任何提交
- 有更新 → `git merge` 合并到 `main` 并推送，紧接着重建镜像

推送时用的是 `GITHUB_TOKEN`，GitHub 不会用这个 token 的推送再去触发 push 事件，
所以 workflow 里显式地 `uses:` 调用了构建流程 —— **不会出现一次同步触发两次构建**。

**合并策略**

- 默认 `theirs`：出现冲突时以上游为准（最适合「只想要上游最新代码」的 fork）
- 设 `SYNC_CONFLICT_STRATEGY=ours` 则本地改动优先
- 设 `fail` 则冲突时直接失败并通知你手动处理
- `.github` 目录被列入 `PROTECTED_PATHS`，合并后强制还原成本地版本，CI 配置不会被上游覆盖
- 上游的历史和本 fork 的历史如果不相通，脚本会自动加 `--allow-unrelated-histories`

**脚本也能在本地跑**

```bash
# 只合并、不推送，先看看会改什么
PUSH=false bash .github/scripts/sync-upstream.sh

# 合并并推送
bash .github/scripts/sync-upstream.sh
```

**注意**：GitHub 的定时任务在仓库连续 60 天无活动后会被自动停用。
本流程每次同步都会产生提交，所以正常情况下不会触发这个限制；如果长期没有上游更新导致被停用，
去 Actions 页面点一次 `Enable workflow` 即可。

---

## 四、部署 + 容器自动更新

```bash
# 1. 准备配置
cp .env.example .env
vim .env      # 至少填 CODEBUDDY_PASSWORD；用 api_key 模式再填 CODEBUDDY_API_KEY

# 2. 启动（主程序 + 自动更新器）
docker compose -f docker-compose.ghcr.yml up -d

# 3. 看日志
docker compose -f docker-compose.ghcr.yml logs -f
```

`docker-compose.ghcr.yml` 里有两个服务：

- `codebuddy2api`：主服务，使用 `ghcr.io/tarocats/codebuddy2api:latest`，`pull_policy: always`
- `watchtower`：每 5 分钟检查一次 GHCR 上 `latest` 是否变新，变新就拉取并**重建**主容器
  （重建而不是 restart，因为 restart 仍然用旧镜像层）
  - 只管理带有 `com.centurylinklabs.watchtower.enable=true` 标签的容器
  - `WATCHTOWER_CLEANUP=true` 会自动删除旧镜像
  - `WATCHTOWER_REMOVE_VOLUMES=false` 保证 `config/`、`.codebuddy_creds/` 不会被删
  - watchtower 镜像取自 `ghcr.io/containrrr/watchtower:1.7.1`，不依赖 Docker Hub

**只想要主服务、不要自动更新：**

```bash
docker compose -f docker-compose.ghcr.yml up -d codebuddy2api
```

**不用 watchtower 的手动更新方式：**

```bash
docker compose -f docker-compose.ghcr.yml pull codebuddy2api
docker compose -f docker-compose.ghcr.yml up -d codebuddy2api
```

也可以把上面两行写进宿主机 crontab 或 systemd timer，效果等价：

```cron
17 */2 * * * cd /opt/CodeBuddy2api && docker compose -f docker-compose.ghcr.yml pull -q codebuddy2api && docker compose -f docker-compose.ghcr.yml up -d codebuddy2api
```

**和原来的 `docker-compose.yml` 有什么区别？**

| | `docker-compose.yml`（原有） | `docker-compose.ghcr.yml`（新增） |
| --- | --- | --- |
| 镜像 | `sliverkiss/codebuddy2api:latest`，且有 `build: .` 会本地构建 | 本 fork 的 GHCR 镜像，不本地构建 |
| 自动更新 | 无 | watchtower 自动重建 |
| 适用场景 | 改源码本地调试 | 部署运行 |

---

## 五、镜像包是 Private 怎么办

GHCR 的包默认是 Private。选择一：按第一节第 3 步改成 Public。

选择二：保持 Private，在服务器上登录一次：

1. GitHub → `Settings → Developer settings → Personal access tokens` 生成一个带 `read:packages` 权限的 token。
2. 服务器上执行：

   ```bash
   echo <YOUR_PAT> | docker login ghcr.io -u TaroCats --password-stdin
   ```

3. 让 watchtower 也带上这份凭据（watchtower 用自己的 `DOCKER_CONFIG`）：

   ```yaml
   # docker-compose.ghcr.yml -> watchtower
   environment:
     DOCKER_CONFIG: /config
   volumes:
     - ~/.docker/config.json:/config/config.json:ro
   ```

   或者更省事，直接在 watchtower 上加账号密码：

   ```yaml
   environment:
     REPO_USER: TaroCats
     REPO_PASS: <YOUR_PAT>
   ```

---

## 六、常见问题

**Q：Actions 报 `denied: permission_denied: write_package`**
A：`Settings → Actions → General → Workflow permissions` 还没设成 Read and write。

**Q：同步 workflow 报 `remote: Permission to ... denied`**
A：同一个权限设置。另外如果 `main` 开了分支保护规则（禁止直接 push），需要把规则改成允许，
或者给 `github-actions[bot]` 加白名单。

**Q：构建很慢**
A：多架构构建要走 QEMU 模拟 ARM，第一次大概 3~6 分钟，之后有 GHA 缓存会快很多。
只是自己用 amd64 的话，手动触发时把 `platforms` 填成 `linux/amd64`。

**Q：怎么确认服务器上是新镜像？**
A：

```bash
docker inspect codebuddy2api --format '{{.Config.Image}} {{.Image}}'
docker compose -f docker-compose.ghcr.yml logs watchtower | tail -20
```

**Q：watchtower 把服务重启了，正在跑的请求会断吗？**
A：会短暂中断（进程被重建）。可以在 `WATCHTOWER_POLL_INTERVAL` 上把检查间隔调大，
或者用 `WATCHTOWER_SCHEDULE` 指定只在凌晨更新，例如 `"0 0 4 * * *"`。

**Q：我不想让上游覆盖我的改动。**
A：把 `SYNC_CONFLICT_STRATEGY` 设为 `ours`，或设为 `fail` 让冲突时直接失败并人工处理；
同时把你想保护的目录加进 `PROTECTED_PATHS`（空格分隔，例如 `.github docker-compose.ghcr.yml`）。
