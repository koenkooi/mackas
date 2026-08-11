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

const localEdits = integrated.filter(Boolean).flatMap((r) => r.localEdits || [])
const externalActions = integrated.filter(Boolean).flatMap((r) => r.externalActions || [])
return { localEdits, externalActions }
```

After the workflow returns: apply `localEdits` yourself (read each target
file fresh, apply the edit, re-verify — don't trust line numbers from
research that ran minutes ago), then list `externalActions` for the user
before running any of them.
