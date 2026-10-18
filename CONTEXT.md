# CONTEXT (glossary) — Hwip plugin push behavior

Glossary only — no implementation detail. Terms for the plugin's notification
behavior.

## Terms

### Stop-hook Push
The automatic completion notification fired by the `Stop` hook after a response
ends. It is reactive (always at end-of-turn) and not initiated by the model.
Distinct from a Proactive Push.

### Proactive Push
A notification the model sends mid-task — before the turn ends — to surface a
blocker, error, or long-running milestone the moment it occurs, rather than
waiting for the end-of-turn Stop-hook Push.

### Meaningful Work
The condition under which a Stop-hook Push is warranted. Today it is approximated
purely by volume (a response that ran enough tool calls). The Push Signal lets the
model correct that approximation per turn.

### Push Signal
A hint the model emits in its own response to steer the Stop-hook Push for that
turn, overriding the volume heuristic. Three intents:
- **Skip** — suppress the push (the work was not Meaningful Work despite its
  volume, e.g. read-only exploration).
- **Push** — force a push even when the volume heuristic would stay silent (a
  small but important action, e.g. a single force-push).
- **High** — force a push and mark it high priority (a blocker or important
  completion the user should see prominently).

When the model emits no Push Signal, the volume heuristic alone decides — so the
plugin behaves exactly as before unless the model speaks up.

### Push Mode
A **user**-set session preference that dials the Stop-hook Push volume, sitting one
level above the model's per-turn Push Signal. Three modes — **normal** (the volume
heuristic decides), **quiet** (only high-priority pushes survive, plus a completion
push when the user is **away** from the terminal), **loud** (every
turn pushes) — set via `/hwip-mode quiet|normal|loud`, mirroring the
mute mechanism. Each dial also takes `--global`, writing the hash-less
`pushmode-default` that every project without its own dial falls back to; a
project dial always outranks it. **With no dial anywhere the mode is `quiet`** —
the shipped default, so `normal` is now something a user opts into rather than
returns to. A dial file that exists but reads empty is treated as `normal`
instead: "no dial" and "broken dial" are different, and resolving breakage to
silence would leave no symptom to debug. Distinct from **Mute**, which is total silence,
overrides any Push Mode, and has no `--global` form (presence-keyed, so it could
never be lifted for one project). Where they conflict, the user's Push Mode wins over the model's Push
Signal (an explicit session preference outranks a per-turn hint).
