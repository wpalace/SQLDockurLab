#!/usr/bin/env bash
# Sync a pinned release of the coding-standards repo into .standards/ and install
# the matching root config files. Safe to re-run: unchanged inputs give no diff.
#
# Configuration (environment variables win over .standards-version):
#   STANDARDS_REPO       git URL of the standards repo
#   STANDARDS_REF        tag to sync, e.g. v1.2.0 (branches are rejected)
#   STANDARDS_LANGUAGES  space-separated subset of: python csharp bash powershell docker terraform
#                        (empty = auto-detect from tracked files)
#   STANDARDS_FORCE=1    overwrite root config files that are not managed by this script
#
# Usage: sync-standards.sh [--upgrade]
#   --upgrade  move STANDARDS_REF to the newest tag with the same major version first
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

readonly VERSION_FILE="${STANDARDS_VERSION_FILE:-.standards-version}"
readonly DEST_DIR=".standards"
readonly MANAGED_MARKER="Managed by coding-standards"
readonly EC_BEGIN="# BEGIN coding-standards (managed by sync-standards.sh)"
readonly EC_END="# END coding-standards"
readonly ALL_LANGUAGES="python csharp bash powershell docker terraform"

die() {
  printf 'sync-standards: error: %s\n' "$*" >&2
  exit 1
}

log() { printf 'sync-standards: %s\n' "$*" >&2; }

# Read KEY=value lines without sourcing the file (no code execution).
read_version_file() {
  local key value
  [[ -f "$VERSION_FILE" ]] || return 0
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key//[[:space:]]/}"
    [[ -z "$key" || "$key" == \#* ]] && continue
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"
    value="${value%\"}"
    case "$key" in
      STANDARDS_REPO) file_repo="$value" ;;
      STANDARDS_REF) file_ref="$value" ;;
      STANDARDS_LANGUAGES) file_languages="$value" ;;
      *) log "ignoring unknown key '$key' in $VERSION_FILE" ;;
    esac
  done <"$VERSION_FILE"
}

write_version_file() {
  printf '%s\n' \
    "# Pinned coding-standards release. Updated by sync-standards.sh --upgrade." \
    "STANDARDS_REPO=$repo" \
    "STANDARDS_REF=$ref" \
    "STANDARDS_LANGUAGES=$configured_languages" >"$VERSION_FILE"
}

list_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files --cached --others --exclude-standard -- . ":(exclude)$DEST_DIR"
  else
    find . -path "./$DEST_DIR" -prune -o -path ./.git -prune -o -type f -print | sed 's|^\./||'
  fi
}

detect_languages() {
  local files found=()
  files="$(list_files)"
  grep -Eq '(^|/)[^/]+\.pyi?$|(^|/)pyproject\.toml$' <<<"$files" && found+=(python)
  grep -Eq '\.(cs|csproj|slnx?)$' <<<"$files" && found+=(csharp)
  grep -Eq '\.(sh|bash)$' <<<"$files" && found+=(bash)
  grep -Eq '\.(ps1|psm1|psd1)$' <<<"$files" && found+=(powershell)
  grep -Eq '(^|/)(Dockerfile[^/]*|[^/]+\.dockerfile|(docker-)?compose[^/]*\.ya?ml)$' <<<"$files" && found+=(docker)
  grep -Eq '\.tf$' <<<"$files" && found+=(terraform)
  printf '%s\n' "${found[*]}"
}

validate_languages() {
  local lang
  for lang in $1; do
    [[ " $ALL_LANGUAGES " == *" $lang "* ]] || die "unknown language '$lang' (valid: $ALL_LANGUAGES)"
  done
}

resolve_upgrade() {
  local major latest
  [[ "$ref" =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]] || die "--upgrade needs a vMAJOR.MINOR.PATCH ref, got '$ref'"
  major="${BASH_REMATCH[1]}"
  latest="$(git ls-remote --tags --refs -- "$repo" "v${major}.*" \
    | awk -F/ '{print $NF}' \
    | grep -E "^v${major}\.[0-9]+\.[0-9]+$" \
    | sort -V \
    | tail -n 1)" || true
  [[ -n "$latest" ]] || die "no v${major}.x.y tags found in $repo"
  if [[ "$latest" != "$ref" ]]; then
    log "upgrading $ref -> $latest"
    ref="$latest"
  fi
}

fetch_release() {
  local src="$1"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" -- "$repo" "$src" \
    || die "cannot clone $repo at $ref"
  # Refuse branches: a pinned tag must resolve to a tag object or lightweight tag.
  git -C "$src" rev-parse --verify --quiet "refs/tags/$ref" >/dev/null \
    || die "'$ref' is not a tag in $repo; pin a release tag"
  [[ -d "$src/skills" ]] || die "$repo@$ref has no skills/ directory"
}

install_tree() {
  local src="$1"
  rm -rf -- "$DEST_DIR"
  mkdir -p -- "$DEST_DIR"
  cp -R -- "$src/skills" "$src/scripts" "$src/templates" "$DEST_DIR/"
  cp -- "$src/VERSION" "$src/CHANGELOG.md" "$DEST_DIR/"
  printf '%s\n' "repo=$repo" "ref=$ref" >"$DEST_DIR/SOURCE"
}

# Copy a managed config to the project root unless the project owns that file.
install_config() {
  local from="$1" to="$2"
  if [[ -f "$to" ]] && ! grep -q "$MANAGED_MARKER" -- "$to" && [[ "${STANDARDS_FORCE:-0}" != 1 ]]; then
    log "skipping $to: project-owned file (set STANDARDS_FORCE=1 to replace)"
    return 0
  fi
  cmp -s -- "$from" "$to" || cp -- "$from" "$to"
}

build_editorconfig_block() {
  local lang fragment
  printf '%s\n' "$EC_BEGIN" \
    "[*]" \
    "charset = utf-8" \
    "end_of_line = lf" \
    "insert_final_newline = true" \
    "trim_trailing_whitespace = true" \
    "" \
    "[*.md]" \
    "trim_trailing_whitespace = false"
  for lang in $languages; do
    fragment="$DEST_DIR/skills/$lang/.editorconfig"
    [[ -f "$fragment" ]] || continue
    printf '\n'
    cat -- "$fragment"
  done
  printf '%s\n' "$EC_END"
}

update_editorconfig() {
  local block_file="$1" out_file="$2"
  build_editorconfig_block >"$block_file"
  if [[ ! -f .editorconfig ]]; then
    {
      printf 'root = true\n\n'
      cat -- "$block_file"
    } >"$out_file"
  elif grep -qF -- "$EC_BEGIN" .editorconfig; then
    awk -v begin="$EC_BEGIN" -v end="$EC_END" -v block="$block_file" '
      $0 == begin { while ((getline line < block) > 0) print line; skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' .editorconfig >"$out_file"
  else
    {
      cat -- .editorconfig
      printf '\n'
      cat -- "$block_file"
    } >"$out_file"
  fi
  cmp -s -- "$out_file" .editorconfig || cp -- "$out_file" .editorconfig
}

# Create agent pointer files once; never overwrite project-edited copies.
install_agent_files() {
  local lang list="" template
  for lang in $languages; do
    list+="- ${lang}: \`$DEST_DIR/skills/${lang}/SKILL.md\`"$'\n'
  done
  if [[ ! -f AGENTS.md ]]; then
    template="$(<"$DEST_DIR/templates/AGENTS.md.template")"
    printf '%s\n' "${template//'{{LANGUAGES}}'/${list%$'\n'}}" >AGENTS.md
    log "created AGENTS.md"
  fi
  local pointer
  for pointer in CLAUDE.md .cursor/rules/standards.mdc .github/copilot-instructions.md; do
    [[ -f "$pointer" ]] && continue
    mkdir -p -- "$(dirname -- "$pointer")"
    cp -- "$DEST_DIR/templates/$pointer" "$pointer"
    log "created $pointer"
  done
}

main() {
  local upgrade=0 lang
  case "${1:-}" in
    --upgrade) upgrade=1 ;;
    "") ;;
    *) die "usage: sync-standards.sh [--upgrade]" ;;
  esac

  command -v git >/dev/null || die "git is required"
  file_repo="" file_ref="" file_languages=""
  read_version_file

  repo="${STANDARDS_REPO:-$file_repo}"
  ref="${STANDARDS_REF:-$file_ref}"
  configured_languages="${STANDARDS_LANGUAGES-$file_languages}"
  [[ -n "$repo" ]] || die "set STANDARDS_REPO or add it to $VERSION_FILE"
  [[ -n "$ref" ]] || die "set STANDARDS_REF or add it to $VERSION_FILE"

  languages="${configured_languages:-$(detect_languages)}"
  validate_languages "$languages"
  [[ -n "$languages" ]] || log "no supported languages detected; syncing skills only"

  ((upgrade)) && resolve_upgrade

  # Global (not local) so the EXIT trap can still see it after main returns.
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf -- "$tmp_dir"' EXIT

  fetch_release "$tmp_dir/src"
  install_tree "$tmp_dir/src"

  for lang in $languages; do
    case "$lang" in
      python) install_config "$DEST_DIR/skills/python/ruff.toml" ruff.toml ;;
      powershell)
        install_config "$DEST_DIR/skills/powershell/PSScriptAnalyzerSettings.psd1" \
          PSScriptAnalyzerSettings.psd1
        ;;
      terraform) install_config "$DEST_DIR/skills/terraform/.tflint.hcl" .tflint.hcl ;;
      docker)
        install_config "$DEST_DIR/skills/docker/.hadolint.yaml" .hadolint.yaml
        install_config "$DEST_DIR/skills/docker/.yamllint.yaml" .yamllint.yaml
        ;;
      *) ;;
    esac
  done

  update_editorconfig "$tmp_dir/editorconfig.block" "$tmp_dir/editorconfig.new"
  install_agent_files
  write_version_file
  log "synced $repo@$ref (languages: ${languages:-none})"
}

main "$@"
