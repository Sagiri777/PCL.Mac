#!/usr/bin/env bash
set -euo pipefail

OUTPUT_PATH="${1:-release-notes.md}"
TRIGGER_REF="${2:-HEAD}"
RELEASE_TAG="${RELEASE_TAG:-Unreleased}"
REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/${GITHUB_REPOSITORY:-}}"

CONTENT_REF="$(git rev-parse "$TRIGGER_REF^" 2>/dev/null || git rev-parse "$TRIGGER_REF")"
PREVIOUS_TAG="$(git describe --tags --abbrev=0 "$CONTENT_REF" 2>/dev/null || true)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

SECTIONS=(breaking feat fix perf refactor docs build chore test style other)
for section in "${SECTIONS[@]}"; do
  : > "$TEMP_DIR/$section"
done

if [[ -n "$PREVIOUS_TAG" ]]; then
  LOG_RANGE="$PREVIOUS_TAG..$CONTENT_REF"
else
  LOG_RANGE="$CONTENT_REF"
fi

COMMIT_COUNT=0
while IFS=$'\t' read -r commit_hash subject; do
  [[ -z "$commit_hash" ]] && continue
  COMMIT_COUNT=$((COMMIT_COUNT + 1))
  short_hash="${commit_hash:0:7}"
  commit_body="$(git show -s --format=%B "$commit_hash")"
  prefix="${subject%%:*}"
  commit_type="${prefix%%(*}"
  commit_type="${commit_type%!}"

  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    entry="- [$short_hash]($REPOSITORY_URL/commit/$commit_hash) $subject"
  else
    entry="- $short_hash $subject"
  fi

  if [[ "$prefix" == *! ]] || grep -qE '^BREAKING[ -]CHANGE:' <<< "$commit_body"; then
    section="breaking"
  else
    case "$commit_type" in
      feat) section="feat" ;;
      fix) section="fix" ;;
      perf) section="perf" ;;
      refactor) section="refactor" ;;
      docs) section="docs" ;;
      build|ci) section="build" ;;
      chore) section="chore" ;;
      test) section="test" ;;
      style) section="style" ;;
      *) section="other" ;;
    esac
  fi

  printf '%s\n' "$entry" >> "$TEMP_DIR/$section"
done < <(git log --reverse --format='%H%x09%s' "$LOG_RANGE")

{
  printf '# PCL.Mac Glass Edition %s\n\n' "$RELEASE_TAG"
  if [[ -n "$PREVIOUS_TAG" ]]; then
    printf '本版本包含从 `%s` 之后到发布提交之前的 **%d** 个提交。\n\n' "$PREVIOUS_TAG" "$COMMIT_COUNT"
  else
    printf '本版本包含发布提交之前的 **%d** 个提交。\n\n' "$COMMIT_COUNT"
  fi

  declare -a titles=(
    'breaking|破坏性变更'
    'feat|新功能'
    'fix|问题修复'
    'perf|性能优化'
    'refactor|代码重构'
    'docs|文档'
    'build|构建与 CI'
    'chore|工程维护'
    'test|测试'
    'style|代码样式'
    'other|其他改动'
  )

  for item in "${titles[@]}"; do
    section="${item%%|*}"
    title="${item#*|}"
    if [[ -s "$TEMP_DIR/$section" ]]; then
      printf '## %s\n\n' "$title"
      cat "$TEMP_DIR/$section"
      printf '\n'
    fi
  done

  printf '## 下载选择\n\n'
  printf -- '- Apple Silicon（M 系列芯片）：`PCL.Mac-%s-arm64.zip`\n' "$RELEASE_TAG"
  printf -- '- Intel Mac：`PCL.Mac-%s-x86_64.zip`\n' "$RELEASE_TAG"

  if [[ -n "$PREVIOUS_TAG" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '\n[查看完整差异](%s/compare/%s...%s)\n' "$REPOSITORY_URL" "$PREVIOUS_TAG" "$RELEASE_TAG"
  fi
} > "$OUTPUT_PATH"

echo "Generated $OUTPUT_PATH with $COMMIT_COUNT commits since ${PREVIOUS_TAG:-repository start}."
