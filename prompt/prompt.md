Project: Azure Arc – Configuration Manager Replacement PoC
Role and objective
Act as a senior Azure infrastructure architect and Azure automation engineer.

Design and build a proof of concept showing how Azure Arc and native Azure services can replace selected Configuration Manager (SCCM) capabilities for Windows Server management. The end goal is a customer demonstration showing how they can centrally manage, monitor, inventory and track configuration changes across their Windows Server estate without relying on Configuration Manager for these capabilities.

The standing rules in .github/copilot-instructions.md apply throughout. That file covers approvals, read-only discovery, no hardcoding, Bicep, AMA only, documentation accuracy and UK spelling.

Knowledge sources
Use the repo skills where relevant: azure-arc, azure-monitor, azure-resource-graph, azure-resource-manager (Bicep and API versions) and azure-policy.
Use the Microsoft Learn MCP server to fetch current documentation. Before using any extension name, extension version, resource API version or KQL table/column, check it against Learn and note the source page in the relevant doc.
If the documentation is unclear or contradicts itself, say aso and propose how to confirm it, rather than guessing.
Customer environment
Existing Azure Arc-enabled Windows Servers in an existing subscription.
Unknown Azure Monitor Agent status.
Unknown Log Analytics Workspace configuration.
Assume there may be existing DCRs, alerts, Action Groups, Change Tracking or VM Insights configuration.
Scope
Core
Server inventory (Azure Arc + Azure Resource Graph)
Performance and Windows event monitoring (AMA + DCRs + Log Analytics)
Software inventory and configuration change tracking (Change Tracking and Inventory with AMA)
Alerting (Azure Monitor alerts + Action Groups)
Reusable KQL query library
Demonstration script and documentation
Stretch
Azure Monitor Workbooks, deployed with Bicep
Design the core so Workbooks can be added later without rework.

Out of scope for this PoC
Patching (Azure Update Manager), application deployment, OS deployment and Machine Configuration. List these in docs/limitations.md as natural next steps, but do not build them.

Phase 1 – Discovery (start here)
Create scripts/discovery/Invoke-ArcDiscovery.ps1. It must use read-only Az PowerShell, Azure CLI and Azure Resource Graph commands only. Parameterise the subscription scope.

Discover and report:

Arc-enabled Windows Servers: name, resource group, location, subscription, OS name and version, Arc agent version, connection status and last status change.
Installed Arc extensions per server, with version and provisioning state. Specifically flag Azure Monitor Agent, Change Tracking, Dependency Agent and any legacy Log Analytics agent (MMA).
Data Collection Rules, their data sources and destinations.
Data Collection Rule Associations per server.
Log Analytics Workspaces: location, retention, pricing tier, and whether the ChangeTracking/VM Insights solutions are present.
Existing Change Tracking and Inventory configuration (AMA-based or legacy Automation-based).
Existing VM Insights configuration.
Existing alert rules (metric, log search, activity log) and Action Groups that target these servers or workspaces.
Relevant Azure Policy assignments (for example AMA, DCR or Change Tracking deployment policies).
Output:

A JSON report and a CSV summary written to scripts/discovery/output/. Add that folder to .gitignore so customer data is never committed.
A short markdown summary (docs/discovery-findings.md) covering: what exists, gaps, conflicts or duplicates, whether an existing workspace should be reused, and recommended next steps.
Then stop and wait for my review.

Phase 2 – Design
Produce docs/architecture.md containing:

A Mermaid architecture diagram and a description of the data flow from server → Arc agent → AMA → DCR → Log Analytics → queries, alerts and workbooks.
A capability mapping table: Configuration Manager feature → Azure replacement → Azure service(s) → gaps or limitations.
Key design decisions, including:
Reuse an existing workspace or create a new one.
Use the VM Insights DCR (InsightsMetrics), a custom performance DCR (Perf), or both, and how to avoid duplicate collection.
How Change Tracking and Inventory is enabled for Arc servers (extension and DCR) and which tables it writes to.
How DCRs and the extension are applied at scale (Bicep for the PoC; Azure Policy for ongoing compliance).
Required resources, dependencies, RBAC roles and prerequisites.
Cost and licensing: Log Analytics ingestion and retention estimates, any per-server charges for Arc-enabled servers, and whether benefits such as Windows Server Management enabled by Azure Arc (Software Assurance / pay-as-you-go licensing) or Defender for Servers change those charges. Verify all of this against current Microsoft documentation.
A deployment and rollback plan.
Then stop and wait for my approval.

Phase 3 – Build
Repository structure
azure-arc-sccm-poc/
├── README.md
├── .github/
│   ├── copilot-instructions.md
│   └── skills/
├── architecture/
├── infra/
│   ├── main.bicep
│   ├── modules/
│   └── parameters/
├── scripts/
│   ├── discovery/
│   ├── deployment/
│   └── demonstration/
├── queries/
├── workbooks/
└── docs/
    ├── architecture.md
    ├── discovery-findings.md
    ├── deployment.md
    ├── validation.md
    ├── troubleshooting.md
    ├── customer-demo-script.md
    └── limitations.md
Infrastructure as code (Bicep)
Use separate modules for: Log Analytics Workspace (conditional — only if not reusing), AMA extension, performance and event DCR, Change Tracking DCR and extension, DCR associations, Action Group, alert rules, and Workbooks.

Parameters must cover: subscription and resource group context, region, workspace name or existing workspace resource ID, Arc server resource IDs, data collection settings, alert thresholds, notification destination(s), and tags.

Use existing references for resources that are already present. Do not create resources that discovery shows already exist and are suitable.

Monitoring data collection
Performance counters: CPU utilisation, available memory, memory utilisation (where reliably available), logical disk free space and utilisation, and key disk performance counters.

Windows event logs: System and Application (Critical, Error and Warning). Make Security event collection optional and off by default, with a note on permissions, privacy and cost. Use XPath filters to avoid excessive data.

Document sample intervals and estimated daily ingestion per server.

Change Tracking and Inventory
Enable the current AMA-based Change Tracking and Inventory for the Arc servers.

It must cover:

Software inventory: name, version, publisher, install and removal detection.
Windows services: state changes, start-type changes, and services that have stopped. Pay particular attention to services.
Registry: a designated set of keys, including a PoC test key.
Files: a designated set of paths, including a PoC test file.
Document collection frequencies, supported limits and the expected delay before changes appear. Do not describe it as real-time.

Alerts
Check which Microsoft recommended alert rules are supported for Arc-enabled servers and use them where available. Where they aren't available, create custom log search alerts.

Candidate alerts: high CPU, low available memory, low disk space, critical Windows events, important service stopped, unexpected software installed, unexpected registry/file change on monitored items, and Arc agent disconnected or AMA heartbeat missing.

For each alert, document the threshold, evaluation frequency, window and rationale, and tune it to avoid noise. Use one parameterised Action Group. Do not duplicate any equivalent alert found in discovery.

KQL query library (queries/)
One .kql file per query, with a header comment describing purpose, source table and expected output:

Server estate inventory (Resource Graph)
Monitoring coverage: servers with/without AMA, DCR association and Change Tracking
CPU, memory and disk utilisation
Windows events (critical and error)
Current installed software
Recent software installations
Recent software removals
Registry changes
File changes
Windows service changes
Services that should be running but are not
Missing heartbeat / monitoring issues
Keep a clear distinction between Resource Graph (Azure resource inventory) and Log Analytics (guest OS data). Do not claim Resource Graph provides SCCM-style hardware inventory.

Workbooks (stretch)
Deploy using Microsoft.Insights/workbooks in Bicep, with the workbook JSON stored in workbooks/.

Server Estate Overview – server count, connected vs disconnected, OS versions, AMA and Change Tracking coverage, servers with monitoring issues.
Server Health – CPU, memory and disk trends, servers over threshold, relevant Windows events.
Software and Configuration Changes – installs, removals, registry, file and service changes, change history per server.
Operational Monitoring – active alerts, critical events, servers needing attention, agent issues, changes to investigate.
Include time-range and server filters, clear visual indicators, tables, charts and drill-down. Administrators should never need to write KQL. If any part can't be deployed through Bicep, document why and provide an alternative method.

Validation of the build
Run az bicep build and az bicep lint, and run what-if against the target scope. Run PSScriptAnalyzer on all PowerShell. Fix any warnings or explain why they're acceptable.

Phase 4 – Deployment (only after my explicit approval)
Deploy incrementally in this order: workspace (if needed) → AMA → DCRs and associations → Change Tracking → Action Group and alerts → Workbooks. Verify each step before moving on. Provide rollback steps in docs/deployment.md.

Phase 5 – Validation
Check and record in docs/validation.md:

Arc connectivity
AMA installed and healthy
DCR associations
Heartbeat, performance and Event data arriving
Change Tracking data arriving
Every KQL query returning results
Alert rules enabled and firing for the test scenarios
Workbooks rendering correctly
Record any issues and their fixes in docs/troubleshooting.md.

Phase 6 – Customer demonstration
Create scripts/demonstration/Invoke-DemoChanges.ps1. Run it against a named test server only. It must be reversible, with a -Revert switch, and must not touch production configuration.

The script should:

Install and later uninstall a small test application
Create and modify a designated test registry key
Create and modify a designated test file
Stop and restart a designated test service
Write a test event to the Application log
Optionally generate a short, controlled CPU load
Write docs/customer-demo-script.md covering the nine demonstration scenarios:

Central view of all servers
CPU, memory and disk monitoring
Windows event monitoring
Installed software inventory
Software installs and removals
Registry and file changes
Windows service status and configuration changes
Querying data with KQL
Alerting on unexpected events
For each scenario, cover: what to show, what the administrator is seeing, which Configuration Manager capability it replaces, which Azure services provide it, the operational benefit, and how long the change takes to appear.