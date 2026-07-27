Real limitations

1. 7-day lookback hard cap — anything older is invisible to the judge, even if still relevant. Long-term context lives in the knowledge base but the judge doesn't read it during this stage.
2. Batch, not real-time — fires once at 3 AM (or on button press). An urgent email at 9 AM won't surface until tomorrow unless you hit Analyze Now.
3. Source-dependent — only sees what's connected. No Slack, Twitter/X, LinkedIn, browser history, external task apps (Todoist/Things/Reminders).
4. Byte budget trims busy weeks — oldest summaries dropped first, so a heavy week can silently lose older candidates (Proactive.swift:79-82).
5. No learning loop beyond tracked tasks — the model doesn't adapt to which suggestions you tend to accept vs. dismiss. Feedback is purely manual (mark Closed/On Hold).
6. Single model, single shot — entirely dependent on gpt-5.6-sol's judgment for ranking; no deterministic fallback or rule-based safety net.

Ideas

- What actually gets added to the list of tasks? I need to see the promtp and decide. for example todos from whatsapp dont get added. neither do things from logseq. which is a bit weird. but perhpas too specific to me? Idk really
- I need it to be able to find things I missed from whatsapp, email and files and suggest things like - clean the downloads folder and such. but these are bigger features so might need more time and thinking. not that I care thaat much. After all its just a timepass project.
