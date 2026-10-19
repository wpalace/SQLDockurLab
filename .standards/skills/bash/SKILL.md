---
name: bash
description: "House coding standard for Bash 5.x scripts. Use when writing, editing, or reviewing shell scripts (*.sh, *.bash, files with a bash/sh shebang)."
---

# Bash Standards

> **Before calling work done:** run the formatter and linter checks in the Formatting section (`shfmt -d -i 2 -ci -bn . && shellcheck <scripts>`) and fix every finding. Reference config: `.editorconfig` beside this file, which `sync-standards.sh` installs at the project root.

**Targets:** Bash 5.3 (released Jul 2025) on Linux CI and containers. Bash 5.0 is the minimum for shared scripts. macOS ships Bash 3.2, so install a current Bash with Homebrew or write POSIX `sh` instead.

Shell scripts are glue. Keep them short and strict, and rewrite them in Python once they grow past about 150 lines or need real data structures.

## Shebang & Strict Mode

- Start every script with `#!/usr/bin/env bash`. Use `#!/bin/sh` only for real POSIX scripts.
- Turn on strict mode immediately. `-E` lets functions and subshells inherit the `ERR` trap.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit nullglob
IFS=$'\n\t'
```

- `-e` doesn't apply inside `if` conditions or on the left side of `&&` or `||`. Check those explicitly.

## Quoting Rules

- **Quote every expansion:** `"$var"`, `"${array[@]}"`, `"$(command)"`.
- Use `${var}` next to other text: `"${name}_backup"`.
- Supply defaults explicitly under `set -u`: `"${1:-}"`, `"${LOG_LEVEL:-info}"`.

```bash
cp -- "$src" "$dest_dir/"
for f in "${files[@]}"; do process "$f"; done
```

## Formatting

Code is formatted for human readability and review. A formatter settles layout so reviewers can focus on logic.

- Format with **shfmt**: `-i 2 -ci -bn` (2-space indent, indented `case` branches, binary operators at the start of a line). Put these flags in `.editorconfig` so editors agree. CI runs `shfmt -d -i 2 -ci -bn .`.
- Keep lines under 100 characters. Put one command per line. Use `;` only in `if ...; then` and `for ...; do`.
- Break long commands one flag per line with trailing `\`, or better, build them in an array.
- Put a blank line between functions and between logical steps. Order the file as header, constants, functions, then `main`.
- Write comments that explain *why* (a workaround or an odd flag), not *what*. Don't mix reformatting with logic changes in one PR.

```bash
# Before
curl -fsSL --retry 3 --retry-delay 2 -H "Authorization: Bearer $token" -o "$out" "$url"

# After
curl_args=(
  --fail --silent --show-error --location
  --retry 3 --retry-delay 2
  --header "Authorization: Bearer $token"
  --output "$out"
)
curl "${curl_args[@]}" "$url"
```

## Structure & Naming

- Name functions and locals in `snake_case`. Constants and exports use `UPPER_SNAKE_CASE`.
- Use `local` inside functions and `readonly` for constants. End the script with `main "$@"`.

```bash
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

backup_database() {
  local db_name="$1"
  pg_dump -- "$db_name" > "${BACKUP_DIR}/${db_name}.sql"
}

main() { backup_database "${1:?usage: backup.sh <db>}"; }
main "$@"
```

## Error Handling

- Define a `die` helper that writes to stderr. Clean up with `trap ... EXIT`. Report failures with `trap ... ERR`.
- Create temp files with `mktemp`. Check dependencies up front.

```bash
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
trap 'printf "failed at %s:%s\n" "${BASH_SOURCE[0]}" "$LINENO" >&2' ERR

command -v jq >/dev/null || die "jq is required"
```

## Modern Bash (5.3) Features

Use these only in scripts that guard the version:

```bash
(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )) \
  || die "requires bash >= 5.3"
```

- **`${ cmd; }`** runs command substitution in the current shell, with no fork. It is faster in loops, and side effects persist.
- **`${| cmd; }`** expands to the value `cmd` leaves in `REPLY`, which is handy for returning values from functions without a subshell.
- **`GLOBSORT`** controls glob order. For example, `GLOBSORT=-mtime` lists newest first, which replaces `ls -t` parsing.
- **`source -p PATH file`** sources from an explicit search path.

```bash
latest_log() { local GLOBSORT=-mtime; local logs=("$1"/*.log); REPLY="${logs[0]:-}"; }
newest=${| latest_log /var/log/app; }
```

- Older but underused: use `$EPOCHREALTIME` for timing, `mapfile -t` to read lines into arrays, and `printf -v` to assign without a subshell.

## Portable vs Bash-Specific

- Choose one target. With a `bash` shebang, use `[[ ]]`, arrays, `(( ))`, `local`, and `mapfile` freely.
- For `/bin/sh` targets (Alpine, dash, distroless shells), use POSIX only: no arrays, `[[ ]]`, `local`, or `${ ; }`.
- Use `printf` instead of `echo` for anything that isn't a literal.

## Tooling

- Run **ShellCheck** in CI with no exceptions. Disable a rule only inline, with a comment explaining why.
- Test behavior with **Bats** (`bats-core`): exit codes, output, and failure paths.

```bash
shellcheck bin/*.sh && bats test/
```

## Avoid

- **Unquoted variables.** They cause word splitting and globbing bugs.
- **`eval`.** Build commands with arrays instead:

```bash
args=(--verbose --output "$out")
rsync "${args[@]}" "$src" "$dest"
```

- **Parsing `ls` output.** Use globs (with `nullglob`), `GLOBSORT`, or `find -print0`:

```bash
find "$dir" -name '*.log' -mtime +7 -print0 | xargs -0 rm --
```

- Backticks, `cd` without `|| die`, `cat file | grep`, and secrets in command-line arguments.
- Using 5.3-only syntax in scripts that may run on older Bash without a version guard.

## Sources

- Kurtuluş ÖZ, "Bash 5.3 Released: Command Substitution and Beyond" (Medium, Jul 2025)
- Heinan Cabouly, "Bash 5.3 Is Here: The Shell Update That Actually Matters" (Medium, Jul 2025)
- GNU Bash 5.3 NEWS (ftp.gnu.org/gnu/bash)
