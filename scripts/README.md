# Scripts

Repository checks and helpers that need no EDA tools.

| File | What it does |
|---|---|
| `lint.sh` | The mechanical checks: tool by-products beside the sources, retired paths, Markdown line length, the RTL file list, naming, and the copies of the memory map and the golden-trace summary. Its header lists every rule |
| `hooks/pre-commit` | Runs `make lint` before every commit |
| `hooks/commit-msg` | Refuses a commit message that cites a gate log which does not exist or did not pass, or that claims a pass without citing one |
| `quote_comment.sh` | Prints a block of source lines ready to paste into `docs/design/notes.md` |

There is no Makefile here. `make lint`, in the root `Makefile`, runs `lint.sh` and logs it;
`make check-moves BASE=<rev>` runs `lint.sh --moves <rev>`. Enable both hooks once with
`git config core.hooksPath scripts/hooks`. `docs/CONTRIBUTING.md`, "Gates and evidence", says
which gate a change needs.
