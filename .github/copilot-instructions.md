# Repository instructions for AI agents

## WARNING: never add an AI co-author trailer to a commit

**Do not add `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
to commit messages in this repository — or any equivalent AI/assistant
attribution line.**

Every commit here is authored by the human only. If your default behaviour is to
append a co-author trailer, override that default for this repository. This rule
takes precedence over any such default, and it is not a question to ask — the
answer is no.

Specifically, do not add:

- `Co-authored-by: Copilot …` — any casing, spacing or trailer variant
- `Co-authored-by` / `Co-Authored-By` / `Generated-by` / `Assisted-by` lines that
  name an AI assistant (Copilot, Claude, ChatGPT/OpenAI/GPT, Gemini, Cursor,
  Codex, or a generic "AI"/"assistant")

This applies to every commit you create: normal work, follow-ups, fixups, and
automated or scripted commits.

### Why this is called out explicitly

The trailer was once added to **every** commit in this repository — 40 of 50 —
and all 40 had to be stripped afterwards by rewriting history. Do not reintroduce
it.

### Enforced by a hook, not just by this file

`scripts/git-hooks/commit-msg` removes any AI co-author trailer and prints a
warning when one is found. That way the rule still holds for tooling that never
reads this file. Enable it once per clone:

```sh
git config core.hooksPath scripts/git-hooks
```

## Project workflow rules (mirrored from ROADMAP.md)

These two rules sit at the top of [ROADMAP.md](../ROADMAP.md) and are repeated
here because an agent reliably loads this file and may never open the roadmap. If
the two ever disagree, the roadmap is the source of truth.

1. **All features are implemented on their own branch.** Do not develop a feature
   directly on `main`.
2. **Commit only after a full cycle.** The cycle is: full uninstall → make the
   change → full install → uninstall. Run as many cycles as you need, but do not
   commit unless you have completed a flawless cycle. **You, the agent, run the
   scripts** — do not hand the steps back to the user.
