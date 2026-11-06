Resume the Azure Arc Configuration Manager replacement PoC.

I approved the Phase 2 design for Phase 3 Build only. Read
.github/copilot-instructions.md, README.md, docs/architecture.md,
docs/discovery-findings.md and docs/deployment.md. Inspect git status and
preserve all existing tracked and untracked work.

The Build is incomplete. Continue from the existing Bicep modules and draft
queries: finish the entry point, reuse-first preflight and deployment tooling,
alerts, query library, reversible demo script, tests and documentation.
Validate the existing drafts rather than assuming they are correct; in
particular, check service-state reconciliation and missing-heartbeat handling.

Use the existing owner-nominated arc-loganalytics workspace. Ignore
MCAPS/default workspaces. The servers are deliberately powered off; do not
treat their current disconnection as a fault. Avoid duplicate collection or
alerts, preserve existing suitable resources, and do not introduce deprecated
agents or features.

Use the repository's Azure skills, Microsoft Learn MCP and Bicep MCP where
relevant. Verify current resource schemas, extension versions and KQL columns.
Target US$200/month for attributable PoC running costs, with estimates
provisional until existing costs, ingestion and licensing are confirmed.

PowerShell is now available. Run the relevant local tests, Bicep build and
lint, and PSScriptAnalyzer on PowerShell scripts and tests. Run a target-scope
what-if where access and reviewed parameters permit. Report any unavailable
tools or validation blockers explicitly.

Do not deploy, delete or modify Azure resources, change guest systems, power
on servers, or run the demo. Prepare an itemised cleanup/cutover plan and stop
for my explicit deployment approval. Keep customer IDs, notification
destinations and discovery output private and out of Git.