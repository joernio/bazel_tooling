#!/usr/bin/env bash
# Generated from bazel_tooling//scalafix:scalafix_runner.sh.tpl, see defs.bzl for documentation.
set -euo pipefail

RUNFILES="${RUNFILES_DIR:-$0.runfiles}"
CLI="$RUNFILES/%CLI%"
TOOL_CLASSPATH_RF="%TOOL_CLASSPATH%"
RULES=(%RULES%)
TARGETS=(%TARGETS%)
SCALA_VERSION="%SCALA_VERSION%"
DIFF_BASE="%DIFF_BASE%"
CHECK="%CHECK%"
BAZEL="${BAZEL:-bazel}"

ALL=0
ONLY_FILES=()
CUSTOM_TARGETS=()
EXTRA_ARGS=()
while (($# > 0)); do
  case "$1" in
    --diff-base) DIFF_BASE="$2"; shift 2 ;;
    --diff-base=*) DIFF_BASE="${1#--diff-base=}"; shift ;;
    --all) ALL=1; shift ;;
    --files) ONLY_FILES+=("$2"); shift 2 ;;
    --files=*) ONLY_FILES+=("${1#--files=}"); shift ;;
    --check) CHECK=1; shift ;;
    --target) CUSTOM_TARGETS+=("$2"); shift 2 ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

if ((${#CUSTOM_TARGETS[@]} > 0)); then
  TARGETS=("${CUSTOM_TARGETS[@]}")
fi

TOOL_CLASSPATH=""
IFS=':' read -r -a TOOL_CLASSPATH_ENTRIES <<<"$TOOL_CLASSPATH_RF"
for entry in "${TOOL_CLASSPATH_ENTRIES[@]}"; do
  TOOL_CLASSPATH="${TOOL_CLASSPATH:+$TOOL_CLASSPATH:}$RUNFILES/$entry"
done

cd "$BUILD_WORKSPACE_DIRECTORY"
WORKSPACE="$PWD"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The set of files to look at. Empty file and ALL=1 means everything.
CHANGED="$TMP/changed"
if ((${#ONLY_FILES[@]} > 0)); then
  printf '%s\n' "${ONLY_FILES[@]}" | sort -u >"$CHANGED"
elif ((ALL == 0)); then
  MERGE_BASE="$(git merge-base "$DIFF_BASE" HEAD)"
  {
    git diff --relative --name-only --diff-filter=d "$MERGE_BASE" -- '*.scala'
    git ls-files --others --exclude-standard -- '*.scala'
  } | sort -u >"$CHANGED"
  if [[ ! -s "$CHANGED" ]]; then
    echo "scalafix: no Scala files changed compared to $DIFF_BASE." >&2
    exit 0
  fi
fi

ASPECT_ARGS=(--aspects='%ASPECT%' --output_groups='%MANIFEST_OUTPUT_GROUP%')

echo "scalafix: building sources and SemanticDB ..." >&2
"$BAZEL" build --show_result=0 "${ASPECT_ARGS[@]}" -- "${TARGETS[@]}" >&2
EXECROOT="$("$BAZEL" info execution_root)"
"$BAZEL" cquery "${ASPECT_ARGS[@]}" --output=files -- "${TARGETS[@]}" 2>/dev/null |
  grep '\.scalafix_manifest$' | sort -u >"$TMP/manifests"

STATUS=0
while IFS= read -r manifest; do
  SRCS=()
  OPTS=()
  CLASSPATH=""
  LABEL=""
  while IFS= read -r line; do
    value="${line:1}"
    case "${line:0:1}" in
      N) LABEL="$value" ;;
      S) SRCS+=("$value") ;;
      O) OPTS+=(--scalac-options "$value") ;;
      J) CLASSPATH="${CLASSPATH:+$CLASSPATH:}$EXECROOT/$value" ;;
    esac
  done <"$EXECROOT/$manifest"

  FILES=()
  COUNT=0
  for src in "${SRCS[@]}"; do
    if [[ -f "$src" ]] && { ((${#ONLY_FILES[@]} == 0 && ALL == 1)) || grep -qxF -- "$src" "$CHANGED"; }; then
      FILES+=(--files "$src")
      COUNT=$((COUNT + 1))
    fi
  done
  if ((${#FILES[@]} == 0)); then
    continue
  fi

  ARGS=(
    --sourceroot "$WORKSPACE"
    --classpath "$CLASSPATH"
    --tool-classpath "$TOOL_CLASSPATH"
    --scala-version "$SCALA_VERSION"
  )
  for rule in "${RULES[@]}"; do
    ARGS+=(--rules "$rule")
  done
  if [[ "$CHECK" == "1" ]]; then
    ARGS+=(--check)
  fi

  echo "scalafix: $LABEL ($COUNT files)" >&2
  "$CLI" "${ARGS[@]}" ${OPTS[@]+"${OPTS[@]}"} ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} "${FILES[@]}" || STATUS=$?
done <"$TMP/manifests"

exit "$STATUS"
