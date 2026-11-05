Resume the Azure Arc Configuration Manager replacement PoC.

I have approved the Phase 2 design in docs/architecture.md. Proceed with Phase 3 Build only. Read .github/copilot-instructions.md, README.md, docs/architecture.md and docs/discovery-findings.md first. Inspect the existing worktree and preserve previous work.

Use the owner-nominated existing workspace, arc-loganalytics. Ignore MCAPS/default workspaces. Servers are deliberately powered off; do not treat that as a fault. Reuse suitable resources and avoid duplicate collection. Use no deprecated agents or features.

Target US$200/month for attributable PoC running costs. Estimates remain provisional; confirm existing costs, ingestion and licensing before deployment, and obtain approval before exceeding the budget.

Build the core Bicep modules, deployment tooling, KQL library, reversible demo script and documentation. Workbooks remain optional stretch scope. Use the repository skills and Microsoft Learn MCP to verify current documentation. Run the required validation, including what-if where access permits.

Do not deploy, delete, change Azure configuration or run guest changes. Prepare an itemised cleanup/cutover plan and stop for explicit deployment approval.