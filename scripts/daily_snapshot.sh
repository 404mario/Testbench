#!/bin/bash
# 每日 commit + push 助手。不会 git add -A，逐项让用户确认。
# Usage:
#   bash scripts/daily_snapshot.sh                # 交互模式
#   bash scripts/daily_snapshot.sh --dry-run      # 只看不动
#   bash scripts/daily_snapshot.sh --message "X"  # 预设 commit message

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

DRY=0
MSG=""
while [ $# -gt 0 ]; do
    case $1 in
        --dry-run|-n) DRY=1 ;;
        --message|-m) shift; MSG=$1 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
    shift
done

hdr() { printf "\n\033[1;36m==[ %s ]==\033[0m\n" "$*"; }

hdr "Git status"
git status

hdr "Diff stat (vs HEAD)"
git diff --stat HEAD 2>/dev/null || true

hdr "Untracked files (verify not sensitive)"
git ls-files --others --exclude-standard | head -50

# Safety: detect possibly-sensitive files
hdr "敏感文件嗅探"
SUS=$(git ls-files --others --modified --exclude-standard 2>/dev/null | \
      grep -iE '\.env$|credential|secret|password|token|\.pem$|id_rsa|id_ed25519|\.key$' || true)
if [ -n "$SUS" ]; then
    echo "  ⚠ 以下文件名包含可疑关键字，请手动确认："
    echo "$SUS" | sed 's/^/    /'
    echo ""
fi

# Size check: detect big files
BIG=$(git ls-files --others --modified --exclude-standard 2>/dev/null | \
      while read f; do
          [ -f "$f" ] || continue
          sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
          [ "$sz" -gt $((50*1024*1024)) ] && echo "$f ($(numfmt --to=iec $sz))"
      done)
if [ -n "$BIG" ]; then
    echo "  ⚠ 以下文件 >50MB，多半是构建产物，请确认不要 commit："
    echo "$BIG" | sed 's/^/    /'
fi

if [ "$DRY" -eq 1 ]; then
    echo ""
    echo "[dry-run] 不执行任何 add/commit/push"
    exit 0
fi

hdr "交互式 git add -p / git add <file>"
echo "  推荐流程："
echo "    1. 用 git add -p 逐 hunk 选；"
echo "    2. 或 git add <file1> <file2> ... 显式加文件名；"
echo "    3. 完成后回到本脚本按 Enter，或 Ctrl+C 退出。"
echo ""
echo "  你现在在新 shell 里执行 git add，然后 exit / Ctrl+D 回来："
${SHELL:-bash} -i

hdr "Staged files after your selection"
git diff --cached --stat
git diff --cached --name-only | sed 's/^/  /'

if git diff --cached --quiet; then
    echo ""
    echo "  没有 staged 改动，退出。"
    exit 0
fi

if [ -z "$MSG" ]; then
    DEFAULT_MSG="docs/scripts: daily snapshot $(date +%Y-%m-%d)"
    read -r -p "Commit message [$DEFAULT_MSG]: " MSG
    MSG=${MSG:-$DEFAULT_MSG}
fi

hdr "git commit"
git commit -m "$MSG"

hdr "git push"
read -r -p "Push to origin main? [y/N] " ans
case "$ans" in
    y|Y|yes) git push origin main ;;
    *) echo "  跳过 push。手动: git push origin main" ;;
esac

hdr "Done"
git log -1 --stat
