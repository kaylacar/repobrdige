# repobrdige

repobrdige is a backend for public repo tracking and repo-facing draft generation.

Current product spine:

- mirror a public repo into a managed local clone
- derive a structured context pack from the latest upstream state
- detect whether the upstream delta is meaningful
- generate a post-ready outbound repo message draft tied to the exact upstream commit

The executable v1 path is PowerShell-first because this machine blocks Node subprocesses from invoking Git directly.

## Commands

```powershell
powershell -ExecutionPolicy Bypass -File .\repobrdige.ps1 -Command track -Id llm-c -Url https://github.com/karpathy/llm.c.git
powershell -ExecutionPolicy Bypass -File .\repobrdige.ps1 -Command sync -Id llm-c
powershell -ExecutionPolicy Bypass -File .\repobrdige.ps1 -Command status -Id llm-c
powershell -ExecutionPolicy Bypass -File .\repobrdige.ps1 -Command watch -IntervalSeconds 300
powershell -ExecutionPolicy Bypass -File .\repobrdige.ps1 -Command watch-status
powershell -ExecutionPolicy Bypass -File .\repobrdige.ps1 -Command serve -Port 8787
```

Then open `http://127.0.0.1:8787/app`.

Optional:

```powershell
powershell -ExecutionPolicy Bypass -File .\repobrdige.ps1 -Command track -Id llm-c -Url https://github.com/karpathy/llm.c.git -Focus "upstream changes relevant to downstream integrations"
```

## Local Data Layout

- `data/mirrors/<repo-id>`: managed local clone
- `data/repos/<repo-id>/config.json`: tracking configuration
- `data/repos/<repo-id>/state.json`: sync and analysis state
- `data/repos/<repo-id>/context/<commit>.json`: context pack for an analyzed commit
- `data/repos/<repo-id>/drafts/<id>.json`: outbound message drafts

## Notes

- V1 is local-only and does not auto-post to GitHub.
- Drafts are marked `superseded` when a newer upstream sync invalidates them.
- The mirror clone is managed by this tool and can be safely refreshed independently from user repos.
- Run the local verification suite with `powershell -ExecutionPolicy Bypass -File .\test.ps1`.
- `watch` syncs every tracked repo, not just one repo id. Use `-Iterations 1` for a single scheduled cycle test.
- `serve` starts the v2 HTTP surface. It exposes `/health`, `/repos`, `/repos/{id}/status`, `/repos/{id}/sync`, and `/watch-status`.
- `/app` is the first human-facing shell on top of the current API.
- Deferred product ideas are listed in [`NOT-YET.md`](C:\Users\teche\repobrdige\NOT-YET.md).
