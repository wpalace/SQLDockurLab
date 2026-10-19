# Python style guide

> **Before calling work done:** run the formatter and linter checks in the Formatting section (`ruff format --check . && ruff check .`) and fix every finding. Configuration: `ruff.toml` (and `runtime/ruff.toml`) at the repository root. `tests/standards-check.sh` runs every check; see [CI.md](../CI.md).

**Targets:** Python 3.14 as the baseline for new projects. Python 3.15 (released Oct 9, 2026) is allowed once your dependencies support it. Tooling: uv 0.13+, Ruff 0.17+.

We follow PEP 8 and let tools make the formatting decisions, so reviews can focus on design.

## Formatting

Code is formatted for human readability and review. A formatter settles layout so reviewers can focus on logic.

- Format with **`ruff format`** (Black-compatible). Lint with **`ruff check`**, which also sorts imports (`I`). Pre-commit runs both, and CI runs `ruff format --check && ruff check`.
- Set line length to **100**. Ruff understands 3.14 syntax, including t-strings. Keep `target-version` in step with `requires-python`.
- Put one statement per line. Separate top-level definitions with two blank lines and logical blocks with one.
- Rely on the **magic trailing comma**: a trailing comma keeps calls, literals, and signatures one item per line, so each diff is one line.
- Write docstrings for *what* and the contract, and comments for *why*. Don't mix reformatting with logic changes in one PR.

```toml
[project]
requires-python = ">=3.14"

[tool.ruff]
line-length = 100
target-version = "py314"

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP", "SIM", "N"]
```

```python
# Before
client = ApiClient(base_url=settings.api_url, timeout=30, retries=3, session=session)

# After (trailing comma keeps it exploded)
client = ApiClient(
    base_url=settings.api_url,
    timeout=30,
    retries=3,
    session=session,
)
```

## Imports

- Group imports as standard library, third-party, then local (Ruff sorts them). Use absolute imports.
- Don't put side effects at import time.
- On 3.15+, use **`lazy import`** for heavy, rarely used modules in CLIs and startup-sensitive code. It is allowed at module scope only, and import errors surface on first use.

```python
lazy import pandas as pd  # 3.15+: loaded only when pd is first touched
```

## Type Hints

- Type hints are **required** on all public functions, methods, and class attributes.
- Use modern syntax: `list[str]`, `X | None`, and `type Alias = ...` statements.
- Annotations are evaluated lazily as of 3.14 (PEP 649/749). Drop `from __future__ import annotations` and quoted forward references in new code.
- Run **mypy** or **pyright** in strict mode on new code. Use `dataclass` or Pydantic models instead of loose dicts.

```python
def load_users(path: Path, *, active_only: bool = True) -> list[User]: ...
```

## Environments & Dependencies

- Use **uv** for everything: `uv init`, `uv add`, `uv sync`, `uv run`, and `uv python install 3.14`.
- `pyproject.toml` is the single source of truth. Commit `uv.lock`. CI and Docker run `uv sync --frozen`.
- Keep dev tools in dependency groups (`uv add --dev pytest ruff mypy`). Run one-off tools with `uvx`.
- Pin the interpreter with `.python-version`. Never `pip install` into the system Python.

## Function & Class Design

- Keep functions small and single-purpose. Make options keyword-only after `*`.
- Prefer plain functions and modules. Use a class when there is state or an interface to model.
- Use `@dataclass(frozen=True, slots=True)` for value objects, and `frozendict` (3.15+) for immutable mappings and constants.
- Pass dependencies in instead of creating them inside a function. Use `pathlib.Path` and f-strings.
- Use **t-strings** (`t"..."`, 3.14) wherever user values meet SQL, HTML, shell, or logs, and let a processor escape them. Never build those strings with f-strings.

```python
from string.templatelib import Template

query: Template = t"SELECT * FROM users WHERE name = {name}"
rows = db.execute(query)  # the driver escapes each interpolation
```

## Concurrency & Performance

- Use `asyncio` for I/O-bound work and `concurrent.futures` for CPU-bound work.
- The **free-threaded build** (`python3.14t`) is officially supported but optional. Adopt it only after you have benchmarked your workload and confirmed that your C extensions support it.
- Profile before optimizing. Use the 3.15 `profiling` package (the Tachyon sampling profiler) or `py-spy` against live processes.

## Error Handling

- Catch specific exceptions close to the source. Define one base error per package.
- Chain exceptions with `raise ... from err`. Use `logging` (or `structlog`) and `logger.exception`, not `print`.
- Don't use `return`, `break`, or `continue` inside `finally`. As of 3.14 it raises a `SyntaxWarning`, and Ruff `B012` catches it.

```python
try:
    raw = path.read_text()
except FileNotFoundError as err:
    raise ConfigError(f"Missing config: {path}") from err
```

## Avoid

- **Mutable default arguments.** Use `None` and create the value inside the function.

```python
def add_tag(tag: str, tags: list[str] | None = None) -> list[str]:
    tags = [] if tags is None else tags
    tags.append(tag)
    return tags
```

- **Bare `except:`.** Catch specific types. At the top level, catch `Exception`, log it, and re-raise.
- **Wildcard imports** (`from module import *`).
- f-strings for SQL or shell commands, global mutable state, `assert` for validation, and unexplained `type: ignore`.

## In this project

- The only Python file is `runtime/qmp.py`. It runs inside the runtime image (Debian, Python 3.13),
  so `runtime/ruff.toml` sets `target-version = "py313"`. It is a frozen runtime image input and is
  excluded from ruff while the image is frozen (see `AGENTS.md`).

## Sources

- Monika Zakaryan, "Python 3.14 is Here! Top Features and Tool Updates to Check Out" (Medium, Oct 25, 2025)
- Dr. Nimrita Koul, "What is new in Python 3.14.0" (Medium, Oct 11, 2025)
- Python.org, "Python 3.15.0" release notes (Oct 9, 2026)
