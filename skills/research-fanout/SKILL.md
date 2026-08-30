---
name: research-fanout
description: Run a large-scale research pass over many independently-researchable backlog items (TODO items, GitHub issues, doc claims, dependency versions, ...) using cheap small-model agents in parallel, synthesized into polished rewrites by a stronger model. Use when asked to "research all X" / "refresh all Y" / "verify everything in Z" across a real list of items — not for a single research question (just use Agent directly for that) and not general-purpose. Produces PROPOSED changes via structured output; never has the workflow itself post/push/execute anything visible or hard to reverse.
---

# Research fan-out: many cheap researchers, one strong integrator

The shape of task this is for: you have a real LIST of items (not one
question) — TODO.md entries, open GitHub issues, a table of dependency
versions, a set of doc claims — and each one needs independent, genuine
verification against current reality, not another round of guessing from
memory. Doing this by hand, one item at a time, doesn't scale past a
handful. This pattern scales it to dozens of items in one pass, at Haiku
prices, with an Opus-quality final write-up.

**Not for:** a single research question (use `Agent` directly). Not for
"do the research AND make the change live" in one shot when the change is
visible/shared/hard to reverse (see "Never let the workflow act" below).

## The three stages

1. **Enumerate and cluster topics.** List every item that needs research,
   then group tightly-related ones into a single topic (e.g. a TODO item
   and the GitHub issue that duplicates it; two GitHub issues about the
   same underlying question). Don't over-fragment (one agent per trivial
   sub-clause wastes calls) and don't over-merge (cramming five unrelated
   concerns into one topic makes the agent's output mushy and impossible to
   apply cleanly). A topic should be answerable by one focused research
   pass and land as one coherent update.

2. **Research phase — one small model per topic, in parallel
   (`pipeline`).** Each agent: reads the CURRENT real text of what it's
   researching (don't trust a snapshot taken earlier — have the agent
   `grep`/`gh issue view`/read the file itself, live, as its first step),
   then does REAL web research (search, fetch real pages, clone real
   source and read it if useful — remove the clone afterward). It must be
   allowed, explicitly, to say "nothing has changed" — a schema field like
   `nothing_changed: boolean` stops agents from inventing busywork to have
   something to report. Model: `haiku` (or whatever "small model" resolves
   to) — this stage is high-volume and doesn't need deep reasoning, just
   real lookups. Expect the odd hole: in the 22-topic run this pattern
   came from, one research agent finished without ever calling structured
   output and its slot came back empty. `pipeline` keeps the position but
   leaves nothing in it, so everything downstream has to tolerate a
   missing entry rather than assume every slot is filled.

3. **Integration phase — a stronger model, batched, not one-shot-all.**
   Group the researched topics into batches of ~4-5 (context-manageable —
   dumping 20+ full research reports into one call degrades quality and
   risks truncation). One agent per batch, model `opus`, effort `high`:
   given the research findings, decide PER TOPIC whether anything genuinely
   needs rewriting (research finding "nothing changed" should almost always
   mean "no rewrite" — don't reword something for its own sake), and write
   the final polished text in the target document's own established style
   (give the integrator the current text as its style reference, not just a
   description of the style).

Both stages return **structured output** (a JSON schema via `agent()`'s
`schema` option), never free text the orchestrator has to parse. The
research schema should include a field for "what I actually read" (paste
the real current text back) so the integrator doesn't have to re-fetch it.
The integration schema should be an array of proposed edits (item id +
new text), not a full rewritten document — small, reviewable diffs, not a
wall of markdown to eyeball for what changed.

## Never let the workflow act — only propose

The workflow's job ends at structured proposals. It must never itself run
`gh issue comment`/`gh issue close`, `git push`, send a message, or take
any other visible/shared/hard-to-reverse action — even though the agents
inside it technically have the tool access to do so. Two reasons:

- **Public-surface actions need human review before they're visible to
  anyone else**, no matter how good the drafted text is.
- **Trust but verify applies to workflow output too.** A subagent's
  literal actions can exceed what its prompt asked for — e.g. editing a
  file it was only told to *read* for context, because nothing in its
  prompt said not to. Always diff/review what actually happened (and what
  the agents actually returned) before applying anything, even when the
  content looks right at a glance.

The right split: the workflow returns `{ localEdits: [...], externalActions:
[...] }` (or similar). The orchestrating turn applies `localEdits` directly
(safe — it's a file in a repo you already control, and git makes it
reversible), then presents `externalActions` (GitHub comments, closes, any
other outward-facing change) to the user as a plain list before running
any of them for real.

## Check every stage, not just the end

An empty result is ambiguous by default, and that ambiguity is the failure mode this pattern is most prone to: `{ localEdits: [] }` reads identically whether every topic was researched and genuinely needed no change, or every research agent came back empty and nothing was ever looked at. Count both stages explicitly and hand the counts back with the results.

The rules the skeleton below encodes: a research slot only counts as usable if it actually carries the text the agent claims to have read (`text_seen`); zero usable slots is a hard failure, not an empty result set; a partially-filled run is reported as `PARTIAL` with the missing topic ids named, never quietly downgraded to "nothing to change"; the same for integration batches. The workflow's return value carries one `verdict` field -- `COMPLETE` or `PARTIAL` -- so the orchestrating turn has a single thing to branch on rather than having to re-derive it from array lengths.

## Known gotcha: pass data as script literals, not via `args`

The `Workflow` tool's `args` parameter does not reliably reach the script —
`const topics = args.topics` can come back `undefined` even for a
single-item test payload, in both `script` (inline) and `scriptPath`
(resume) invocation paths. **Don't rely on it — embed the topic list
directly as a literal array in the script body** (`const topics = [ {...},
{...} ]`, written straight into the script text you pass to
`script`/edit at `scriptPath`). JSON and JS object-literal syntax are close
enough that you can paste a `JSON.stringify`'d structure in directly. This
sidesteps the issue entirely and costs nothing.

## Skeleton

```js
export const meta = {
  name: 'my-research-fanout',
  description: 'Research N backlog items with small models, Opus integrates',
  phases: [
    { title: 'Research', detail: 'small models research each topic online' },
    { title: 'Integrate', detail: 'a stronger model rewrites and drafts external actions', model: 'opus' },
  ],
}

// Embedded directly -- see "Known gotcha" above, do not use args.topics.
const topics = [
  { id: 'topic-a', focus: 'what to verify, in one sentence', /* ...refs to the real items... */ },
  // ...
]
const batches = [['topic-a', 'topic-b', 'topic-c'], ['topic-d', 'topic-e']] // ~4-5 per batch

const RESEARCH_SCHEMA = { type: 'object', required: ['text_seen', 'findings', 'notes', 'nothing_changed'], properties: {
  text_seen: { type: 'string', description: 'the exact current text you read, verbatim' },
  findings: { type: 'string', description: 'what real research found, with citations' },
  notes: { type: 'string', description: 'specific notes for how the text should change, if at all' },
  nothing_changed: { type: 'boolean' },
} }

const INTEGRATE_SCHEMA = { type: 'object', required: ['localEdits', 'externalActions'], properties: {
  localEdits: { type: 'array', items: { type: 'object', required: ['id', 'newText'], properties: {
    id: { type: 'string' }, newText: { type: 'string' } } } },
  externalActions: { type: 'array', items: { type: 'object', required: ['target', 'action', 'text'], properties: {
    target: { type: 'string' }, action: { type: 'string' }, text: { type: 'string' } } } },
} }

phase('Research')
const researched = await pipeline(topics, (t) =>
  agent(`Research: ${t.focus}\n\nFirst read the CURRENT real text yourself (do not trust anything pre-supplied). Then do REAL online research -- web search, fetch real pages, clone+read real source if useful (remove the clone after). Be honest if nothing changed.`,
    { schema: RESEARCH_SCHEMA, model: 'haiku', phase: 'Research', label: 'research:' + t.id }))

// Checkpoint 1. A slot with no text_seen means that topic was never actually
// researched; without this the miss disappears into an empty localEdits later.
const researchMissing = topics.filter((t, i) => !(researched[i] && researched[i].text_seen)).map((t) => t.id)
if (researchMissing.length === topics.length)
  throw new Error(`RESEARCH FAILED: 0/${topics.length} topics returned usable output`)

phase('Integrate')
const byId = {}
topics.forEach((t, i) => { byId[t.id] = { topic: t, research: researched[i] } })
const integrated = await pipeline(batches, (batchIds) => {
  const context = batchIds.map((id) => {
    const { topic, research } = byId[id]
    // A research agent can finish without ever returning structured output;
    // pipeline keeps the slot but leaves it empty. Guard, don't crash the batch.
    if (!research) return `TOPIC ${id} (${topic.focus}): research returned nothing -- prefer no edit over guessing.`
    return `TOPIC ${id} (${topic.focus})\nTEXT SEEN: ${research.text_seen}\nFINDINGS: ${research.findings}\nNOTES: ${research.notes}\nNOTHING_CHANGED: ${research.nothing_changed}`
  }).join('\n\n---\n\n')
  return agent(`Integrate this research into final text. Only propose an edit where research found something genuinely new -- nothing_changed=true should almost always mean no edit. Match the existing text's own style, don't just reword it.\n\n${context}`,
    { schema: INTEGRATE_SCHEMA, model: 'opus', effort: 'high', phase: 'Integrate', label: 'integrate:' + batchIds.join('+') })
})

// Checkpoint 2, same rule one stage later.
const integrateMissing = batches.filter((b, i) => !integrated[i]).map((b) => b.join('+'))
if (integrateMissing.length === batches.length)
  throw new Error(`INTEGRATION FAILED: 0/${batches.length} batches returned`)

const localEdits = integrated.filter(Boolean).flatMap((r) => r.localEdits || [])
const externalActions = integrated.filter(Boolean).flatMap((r) => r.externalActions || [])
return {
  verdict: researchMissing.length || integrateMissing.length ? 'PARTIAL' : 'COMPLETE',
  counts: { topics: topics.length, researched: topics.length - researchMissing.length,
            batches: batches.length, integrated: batches.length - integrateMissing.length,
            localEdits: localEdits.length, externalActions: externalActions.length },
  researchMissing, integrateMissing, localEdits, externalActions,
}
```

After the workflow returns, read `verdict` before anything else. `PARTIAL` means the topics in `researchMissing`/`integrateMissing` were never covered -- report them as unresearched, never as "nothing to change". A thrown error means the run produced nothing and there is nothing to apply.

Apply `localEdits` one at a time, each with its own check: read the target file fresh (never trust a line number from research that ran minutes ago), confirm the text the edit anchors on is still there verbatim, apply, and confirm it landed. An edit whose anchor no longer matches is a FAILED edit, not a skipped one -- name it in the final report alongside the count of edits that did apply. Then list `externalActions` for the user before running any of them.
