Resume the Azure Arc Configuration Manager replacement PoC.

I approved the Phase 2 design for Phase 3 Build only. Read the repository
instructions and the current architecture, discovery, deployment and validation
documentation. Inspect git status and preserve all tracked and untracked work.

The Build is still incomplete. Finish the fail-closed, reuse-first preflight
and staged tooling. The current cutover review is review-only and must not be
treated as permission to run what-if or deploy. Validate changes with the
existing tests, Bicep build and lint, and PSScriptAnalyzer.

Reuse the nominated arc-loganalytics workspace; ignore MCAPS/default
workspaces. Preserve existing monitoring, DCRs, associations, alerts and
Action Groups. Keep customer IDs, recipients and discovery evidence private
and out of Git.

Investigate the observed extension-version drift and the documented
Change Tracking file-setting and frequency discrepancies. Use current
Microsoft Learn guidance and the repository's Azure skills; do not guess
where the documentation is unclear. Refresh read-only discovery before any
eventual what-if.

The application install/removal demo is deferred. I chose an existing,
designated disposable service for the demo, but have not selected a specific
host or service. Windows integration has not been tested.

The US$200/month attributable cost target remains provisional. Earlier
evidence permissions were corrected, but prior access cannot be established.

Do not deploy, modify or delete Azure resources, change guests, run the demo
or send notifications without my separate explicit approval. Run a target
what-if only after the preflight and exact private parameters are reviewed.
Stop for my approval before deployment.