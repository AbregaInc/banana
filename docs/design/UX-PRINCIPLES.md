# Ongoing UX design practice

Laws of UX is part of Banana’s normal design and review practice. Reference:
[Jon Yablonski’s Laws of UX](https://lawsofux.com/llms.txt), reviewed 14 November 2026.

For each interface or interaction change, begin with the user’s task and the existing flow.
Choose the relevant principles below, make the smallest coherent improvement, and check the
observable result. Review initial, loading, success, empty, interrupted, failed and retry states
as the change requires. A small change needs a brief rationale and an appropriate check, not
an exhaustive worksheet. Keep evidence and tradeoffs in the existing design notes or PR.

Native conventions, accessibility and the [UI performance contract](../performance/ui-performance-contract.md)
remain requirements. The Doherty article’s 400 ms discussion does not loosen our 8.3 ms frame,
under-10 ms direct-input p95, 20 ms direct-input maximum or 100 ms UI ceiling. Do not introduce
artificial latency or fabricate percentages, even where a source example discusses them.

Use grouping and progressive disclosure without hiding essential actions. Miller’s Law is not
a seven-item menu limit. Postel’s Law does not weaken validation or authorization. Visual polish
and psychological explanations do not substitute for task tests, recovery, or device evidence.
Preserve drafts and pending changes, and distinguish unknown information from zero or success.

## Review examples

For sync feedback, group status with the affected count/content, report actual work, show pause
and failure clearly, and remove completed activity. For permission changes, reuse the familiar
account action and explain the requested capability in context. For AI, expose capabilities and
data coverage honestly and preserve the native review path for actions.

## Full principle reference

The following table maps every entry in the source index to a practical review question or action.
These applications are project decisions informed by the reference, not universal proof that an
interface works. Verify the result with the appropriate functional, visual and performance checks.

| Principle | What to do in design and review |
| --- | --- |
| [Aesthetic-Usability Effect](https://lawsofux.com/aesthetic-usability-effect/) | Polish hierarchy and legibility, then verify actual task success; attractive surfaces can conceal problems. |
| [Choice Overload](https://lawsofux.com/choice-overload/) | Reduce competing options and make necessary comparisons easy to see together. |
| [Chunking](https://lawsofux.com/chunking/) | Group information around meaningful tasks and scanning patterns. |
| [Cognitive Bias](https://lawsofux.com/cognitive-bias/) | Challenge designer assumptions, defaults and misleading framing with observed behavior. |
| [Cognitive Load](https://lawsofux.com/cognitive-load/) | Remove irrelevant decisions and expose the context needed for the current action. |
| [Doherty Threshold](https://lawsofux.com/doherty-threshold/) | Respond promptly with accurate feedback; preserve tighter project latency budgets and avoid artificial delays. |
| [Fitts’s Law](https://lawsofux.com/fittss-law/) | Use reachable, adequately sized and spaced targets for the actual input method. |
| [Flow](https://lawsofux.com/flow/) | Preserve context and momentum; avoid unnecessary interruptions and modality changes. |
| [Goal-Gradient Effect](https://lawsofux.com/goal-gradient-effect/) | Make genuine completion and remaining work understandable without fabricating progress. |
| [Hick’s Law](https://lawsofux.com/hicks-law/) | Simplify consequential choices and disclose complexity at the point of need. |
| [Jakob’s Law](https://lawsofux.com/jakobs-law/) | Follow familiar platform patterns and preserve learned behavior during changes. |
| [Law of Common Region](https://lawsofux.com/law-of-common-region/) | Use boundaries or backgrounds when they clarify real relationships; avoid gratuitous containers. |
| [Law of Proximity](https://lawsofux.com/law-of-proximity/) | Keep related controls, status and content near one another; separate unrelated groups. |
| [Law of Prägnanz](https://lawsofux.com/law-of-pr%C3%A4gnanz/) | Prefer clear, orderly shapes and visual structure over ambiguous decoration. |
| [Law of Similarity](https://lawsofux.com/law-of-similarity/) | Give equivalent roles consistent styling and distinguish controls from ordinary content. |
| [Law of Uniform Connectedness](https://lawsofux.com/law-of-uniform-connectedness/) | Use visual connections only where elements genuinely share context or function. |
| [Mental Model](https://lawsofux.com/mental-model/) | Match the person’s understanding of the task, rather than exposing implementation structure. |
| [Miller’s Law](https://lawsofux.com/millers-law/) | Chunk information and support recognition; do not invent a universal seven-item cap. |
| [Occam’s Razor](https://lawsofux.com/occams-razor/) | Choose the simpler solution that preserves the required behavior and recovery paths. |
| [Paradox of the Active User](https://lawsofux.com/paradox-of-the-active-user/) | Let people begin useful work; place necessary guidance in context instead of requiring a manual. |
| [Pareto Principle](https://lawsofux.com/pareto-principle/) | Prioritize frequent, valuable paths using evidence without abandoning accessibility or failures. |
| [Parkinson’s Law](https://lawsofux.com/parkinsons-law/) | Reduce repeated entry and unnecessary steps; reuse confirmed information rather than imposing surprise timers. |
| [Peak-End Rule](https://lawsofux.com/peak-end-rule/) | Review stressful transitions and the final outcome, including clear completion and repair after failure. |
| [Postel’s Law](https://lawsofux.com/postels-law/) | Accept reasonable input variation and produce consistent output while retaining strict validation and intent. |
| [Selective Attention](https://lawsofux.com/selective-attention/) | Keep the current task salient and background activity subordinate. |
| [Serial Position Effect](https://lawsofux.com/serial-position-effect/) | Order actions deliberately and keep important destinations easy to find; avoid gratuitous reordering. |
| [Tesler’s Law](https://lawsofux.com/teslers-law/) | Have the system handle necessary complexity instead of transferring configuration and bookkeeping to people. |
| [Von Restorff Effect](https://lawsofux.com/von-restorff-effect/) | Reserve distinctive emphasis for meaningful priorities; support perception beyond color and motion. |
| [Working Memory](https://lawsofux.com/working-memory/) | Keep relevant state visible and preserve context rather than requiring users to remember it across screens. |
| [Zeigarnik Effect](https://lawsofux.com/zeigarnik-effect/) | Preserve unfinished work and make pending versus completed states clear without manufacturing anxiety. |
