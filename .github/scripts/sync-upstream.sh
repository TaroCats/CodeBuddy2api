#!/usr/bin/env bash
#
# 把上游仓库的新提交合并进当前 fork。
#
# 既可以在 GitHub Actions 中运行（由 .github/workflows/sync-upstream.yml 调用），
# 也可以在本地手动运行：
#
#   PUSH=false bash .github/scripts/sync-upstream.sh      # 只合并，不推送
#   bash .github/scripts/sync-upstream.sh                 # 合并并推送
#
# 可用的环境变量：
#   UPSTREAM_REPO            上游仓库，默认 Sliverkiss/CodeBuddy2api
#                            （支持 owner/repo 简写，也支持完整 URL 或本地路径）
#   UPSTREAM_URL             直接用完整 URL 覆盖 UPSTREAM_REPO 的解析结果
#   UPSTREAM_BRANCH          上游分支，默认 main
#   TARGET_BRANCH            本 fork 的分支，默认 main
#   SYNC_CONFLICT_STRATEGY   冲突处理策略: theirs(上游优先，默认) / ours(本地优先) / fail(直接失败)
#   PROTECTED_PATHS          合并后强制保留本地版本的路径（空格分隔），默认 .github
#   PUSH                     是否推送，默认 true
#
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-Sliverkiss/CodeBuddy2api}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
CONFLICT_STRATEGY="${SYNC_CONFLICT_STRATEGY:-theirs}"
PROTECTED_PATHS="${PROTECTED_PATHS:-.github}"
PUSH="${PUSH:-true}"

log()  { printf '\033[36m[sync-upstream]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[sync-upstream]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[sync-upstream]\033[0m %s\n' "$*" >&2; exit 1; }

set_out() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# UPSTREAM_REPO 支持 "owner/repo" 简写，也支持完整 URL / 本地路径（方便本地自测）
if [ -n "${UPSTREAM_URL:-}" ]; then
  :
elif printf '%s' "$UPSTREAM_REPO" | grep -Eq '://|^/|^\.'; then
  UPSTREAM_URL="$UPSTREAM_REPO"
else
  UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}.git"
fi

case "$CONFLICT_STRATEGY" in
  theirs|ours) ;;
  fail|none)   CONFLICT_STRATEGY="fail" ;;
  *) die "未知的 SYNC_CONFLICT_STRATEGY: '${CONFLICT_STRATEGY}'（可选 theirs / ours / fail）" ;;
esac

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
  warn "当前分支是 '${CURRENT_BRANCH}'，而目标分支是 '${TARGET_BRANCH}'，将切换到目标分支。"
  git checkout "$TARGET_BRANCH"
fi

# 用匿名 HTTPS 拉取上游，无需任何额外密钥
git remote remove upstream >/dev/null 2>&1 || true
git remote add upstream "$UPSTREAM_URL"

log "拉取上游：${UPSTREAM_REPO} -> ${UPSTREAM_URL} (${UPSTREAM_BRANCH}) ..."
git fetch --no-tags upstream "$UPSTREAM_BRANCH" >/dev/null

UPSTREAM_SHA="$(git rev-parse FETCH_HEAD)"
HEAD_SHA="$(git rev-parse HEAD)"
set_out upstream_sha "$UPSTREAM_SHA"
log "上游 HEAD  = ${UPSTREAM_SHA:0:7} (${UPSTREAM_REPO})"
log "本地 HEAD  = ${HEAD_SHA:0:7}"

if git merge-base --is-ancestor "$UPSTREAM_SHA" HEAD; then
  log "✅ 上游没有任何新提交，无需同步。"
  set_out updated false
  exit 0
fi

BEHIND="$(git rev-list --count "HEAD..${UPSTREAM_SHA}")"
log "上游领先 ${BEHIND} 个提交，开始合并（冲突策略：${CONFLICT_STRATEGY}）"

BEFORE="$(git rev-parse HEAD)"
MERGE_ARGS=(--no-commit --no-ff --allow-unrelated-histories)
case "$CONFLICT_STRATEGY" in
  theirs) MERGE_ARGS+=(-X theirs) ;;
  ours)   MERGE_ARGS+=(-X ours)   ;;
esac

if ! git merge "${MERGE_ARGS[@]}" "$UPSTREAM_SHA"; then
  warn "自动合并失败，正在回滚本次合并。"
  git merge --abort 2>/dev/null || git reset --hard "$BEFORE"
  die "上游改动与本地改动存在无法自动解决的冲突（例如文件被一方删除、另一方修改）。请手动解决：
  git fetch ${UPSTREAM_URL} ${UPSTREAM_BRANCH}
  git merge FETCH_HEAD
解决冲突并推送后，镜像会自动重建。"
fi

# 让 fork 自有的文件永远保留本地版本，避免被上游覆盖
for p in $PROTECTED_PATHS; do
  if git cat-file -e "${BEFORE}:${p}" 2>/dev/null; then
    git checkout "$BEFORE" -- "$p"
    log "已还原受保护路径：${p}"
  fi
done

git add -A

if git diff --cached --quiet; then
  log "合并后没有实际文件变化，跳过提交。"
  git merge --abort 2>/dev/null || git reset --hard "$BEFORE"
  set_out updated false
  exit 0
fi

# 用 -c 临时指定提交身份，不污染本地仓库的 git config
git -c user.name="${SYNC_GIT_NAME:-github-actions[bot]}" \
    -c user.email="${SYNC_GIT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
    commit -m "chore(sync): 合并上游 ${UPSTREAM_REPO}@${UPSTREAM_SHA:0:7}

由 .github/workflows/sync-upstream.yml 自动同步。
上游仓库: ${UPSTREAM_REPO}
上游提交: ${UPSTREAM_SHA}
冲突策略: ${CONFLICT_STRATEGY}"

if [ "$PUSH" = "true" ]; then
  git push origin "HEAD:${TARGET_BRANCH}"
  log "✅ 已推送到 origin/${TARGET_BRANCH}。"
else
  log "PUSH=${PUSH}，已在本地完成合并，未推送。"
fi

set_out updated true
log "✅ 同步完成。"
