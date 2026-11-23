#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 在维护者的 Mac 上验证一个 PR 的 macOS 部分，把结果作为提交状态 local/macos 上报到 PR 的头提交。
# 分支保护把 local/macos 设为必需检查，代替 GitHub 托管的 macOS 运行器（那里常要排队，见 macos.yml 开头）。
#
# 用法：scripts/verify_macos.sh <PR 编号>
# 需要：已登录的 gh（对仓库有写权限）、Swift 6 工具链、Python 3.11+。
#
# 做的事，与 macos.yml 的 build 任务的检查步骤一致：
# 1. 把 PR 的头提交检出到临时 worktree，不碰当前工作区，结束时删掉；
# 2. 没有改动 macOS 相关路径时直接上报成功（与 Windows 工作流的路径判断同一思路）；
# 3. 否则依次跑文案生成检查、质量门禁、发布说明标记、文档链接、swift build、swift test；
# 4. 先上报 pending，结束时按结果上报 success 或 failure，说明里写失败的步骤或测试数。
# 打包与签名不在这里做，那些只在推送 tag 时由 GitHub 运行。

set -euo pipefail

PR="${1:?用法：scripts/verify_macos.sh <PR 编号>}"
CONTEXT="local/macos"
# 与 macos.yml 原来的路径过滤相同：这些路径有改动才需要构建 macOS 版。
PATTERN='^(macos/|shared/|scripts/|docs/release-notes/macos/|\.github/workflows/macos\.yml$)'

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
HEAD_SHA="$(gh pr view "$PR" --json headRefOid -q .headRefOid)"
BASE_REF="$(gh pr view "$PR" --json baseRefName -q .baseRefName)"
echo "PR #${PR}：头提交 ${HEAD_SHA}，目标分支 ${BASE_REF}"

# 上报提交状态。description 有 140 字符的上限，调用处保持简短。
report() {
    gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
        -f state="$1" -f context="$CONTEXT" -f description="$2" >/dev/null
    echo "已上报 ${CONTEXT} = $1：$2"
}

REPO_DIR="$(git rev-parse --show-toplevel)"
git fetch --quiet origin "pull/${PR}/head" "$BASE_REF"
WORKTREE="$(mktemp -d /tmp/eveo-verify-XXXXXX)"
# 任何一步失败或被中断，都删掉临时 worktree；状态仍是 pending 时改报 failure，免得 PR 一直等。
STATE="pending"
cleanup() {
    if [[ "$STATE" == "pending" ]]; then
        report failure "本机验证中断" || true
    fi
    # 先离开临时 worktree，再从原仓库删掉它。
    cd "$REPO_DIR"
    git worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
}
trap cleanup EXIT
git worktree add --quiet --detach "$WORKTREE" "$HEAD_SHA"
cd "$WORKTREE"

# 和 GitHub 上的判断一样，比较目标分支与头提交的合并基点。
CHANGED="$(git diff --name-only "origin/${BASE_REF}...${HEAD_SHA}")"
if ! grep -qE "$PATTERN" <<< "$CHANGED"; then
    STATE="success"
    report success "没有改动 macOS 相关路径，跳过构建"
    exit 0
fi

report pending "正在本机构建与测试"

# 依次运行一个检查步骤；失败时上报是哪一步，并以非零退出。
step() {
    local name="$1"
    shift
    echo "== ${name}"
    if ! "$@"; then
        STATE="failure"
        report failure "${name}失败"
        exit 1
    fi
}

step "工具链版本" swift --version
step "文案生成检查" python3 shared/tools/gen_l10n.py --check
step "质量门禁" python3 scripts/check_quality.py macos/Sources macos/Tests
step "发布说明标记" bash -c 'python3 scripts/check_release_notes.py docs/release-notes/macos/*.md'
step "文档链接" python3 scripts/check_links.py
step "swift build" bash -c 'cd macos && swift build'

# swift test 的输出另存一份，从最后的汇总行里取测试数写进状态说明。
LOG="$(mktemp /tmp/eveo-verify-test-XXXXXX)"
step "swift test" bash -c "cd macos && swift test 2>&1 | tee '$LOG'; exit \${PIPESTATUS[0]}"
COUNT="$(grep -oE 'with [0-9]+ tests? passed' "$LOG" | tail -1 | grep -oE '[0-9]+' || true)"
rm -f "$LOG"

STATE="success"
report success "本机构建与测试通过${COUNT:+（${COUNT} 个测试）}"
