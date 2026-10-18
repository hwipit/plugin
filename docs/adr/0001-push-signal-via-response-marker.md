# ADR-0001: Push Signal via in-response marker

## Status
Accepted (2026-06-30). Design from a grill-with-docs session; implementation to follow.

## Context
The `Stop` hook decides whether to send a completion push using a single volume
heuristic: a response that ran ≥2 tool calls gets a push, otherwise it is silent.
This misfires both ways — it spams on read-only multi-tool turns (exploration) and
stays silent on a small-but-important single action (e.g. a force-push). We want
the model, which is the only component that understands what the turn *meant*, to
steer the push per turn (skip / force / high priority).

The model needs a channel to emit that Push Signal back to the bash `Stop` hook.
Three were considered (see Alternatives).

## Decision
The model emits the Push Signal as an HTML comment in its own response text:
`<!-- hwip: skip -->`, `<!-- hwip: push -->`, or `<!-- hwip: high -->`. The `Stop`
hook greps the last assistant text (which it already extracts for the push body)
for the marker and lets it override the volume heuristic. Three intents: `skip`
(suppress), `push` (force a push the heuristic would skip), `high` (force + high
priority).

When no marker is present the hook falls back to a heuristic floor: a turn whose
tools are all read-only (Read/Grep/Glob) is skipped; otherwise the existing ≥2-tool
rule applies. So absence of a marker preserves prior behavior — the marker is a
pure override layer.

## Consequences
- **Good:** Lives entirely in the plugin (`Stop` hook + `CORE_RULES.md`). No MCP
  protocol change, no new tool, no coupled `mcp-server` release. The hook already
  reads the assistant text, so detection is one grep. Graceful degradation: if the
  model omits the marker, the heuristic floor still runs.
- **Cost:** The marker is soft — it depends on the model following a rule, not a
  guaranteed tool contract. The B1 heuristic floor is the deterministic backstop.
  The marker string lives in the transcript text. It is invisible as an HTML
  comment in the *terminal* (markdown-rendered), but a push notification renders
  **plaintext** — so the hook MUST strip the marker from the push body before
  sending, or `<!-- hwip: high -->` shows up verbatim on the phone. Stripping is
  therefore mandatory (not cosmetic), and the detect and strip patterns must be
  identical so a slightly-malformed marker can never be detected-but-not-stripped.
- **Cost (latency):** The final assistant text lands a beat after the Stop hook
  fires, so marker detection needs a short bounded re-read. A naive "retry until
  text appears" above the skip gate would make every fast-exit (skip) turn block
  ~1s — so the retry is bounded and the full body re-read runs only once a push is
  already decided.
- **Cost (missed marker):** Because the marker re-read is *bounded* (it must not
  tax fast-exit turns), a marker that flushes slower than the bound is missed and
  the turn falls back to the volume heuristic — a `skip` on a heavy turn still
  pushes, a `push` on a sub-threshold turn stays silent. This degrades gracefully
  (an extra ping, or a missing one — never a wrong destructive action) and the B1
  floor still governs, but the model's explicit signal can be silently dropped.
  If this proves too unreliable in practice, the escape hatch is the rejected
  alternative below: a `hwip_signal` MCP tool writes a `tool_use` entry
  synchronously as the turn runs (no late text flush), eliminating the timing gap
  entirely. We accept the soft marker first because it ships in the plugin alone.
- **Correctness note:** detect and strip must use a whitespace class that does not
  span newlines (`[[:blank:]]`, not `[[:space:]]`) — bash matches the whole
  multiline buffer while sed strips line-by-line, so a newline-spanning class would
  let bash detect a marker sed cannot strip (an asymmetric leak). With
  `[[:blank:]]` a newline-split marker is honoured by neither: it is simply not a
  marker.

## Alternatives considered
- **Dedicated `hwip_signal` MCP tool:** cleaner (no text pollution, a real tool
  contract the hook detects like it already detects `hwip_ask`). Rejected for now:
  adds a tool to the surface and couples a `mcp-server` release to a plugin-only
  change. Revisit if the soft marker proves unreliable in practice.
- **Reuse `hwip_notify` for the signal:** `notify` is an action (it sends), so it
  cannot express *skip* — it would only cover the `high` case. Rejected: leaves
  half the gating (noise suppression) unsolved.

## Related
- Proactive Push hardening (errors/blockers fired mid-turn) is a separate, code-free
  `CORE_RULES.md` change shipped alongside this — not part of this decision.
- Glossary: see `CONTEXT.md` (Push Signal, Stop-hook Push, Proactive Push,
  Meaningful Work).
