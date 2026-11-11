# Scripts

Repository checks that need no EDA tools, and the git hook that runs them.

| File | What it does |
|---|---|
| `lint.sh` | The mechanical checks: tool by-products beside the sources, Markdown line length, the RTL file list, naming, and the copies of the memory map and the golden-trace summary. Its header lists every rule |
| `hooks/pre-commit` | Runs `make lint` before every commit |

`make lint`, in the root `Makefile`, runs `lint.sh` and logs it; CI (`.github/workflows/lint.yml`)
runs it on every push. Enable the hook once with `git config core.hooksPath scripts/hooks`.
