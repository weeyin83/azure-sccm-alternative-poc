# Discovery findings

## Status

**Read-only discovery completed on 5 November 2026 at 15:51 UTC** across the
three explicitly approved subscriptions. All **298 checks succeeded**. The
report status is **CollectedPendingReview**, not validated monitoring health.
No Azure resources, agents, collection settings or alerts were changed.

The read-only collector is [Invoke-ArcDiscovery.ps1](../scripts/discovery/Invoke-ArcDiscovery.ps1).
See [the run instructions](../README.md) for prerequisites and execution.
Raw evidence is in the ignored output directory; this document contains only
sanitised conclusions. The owner's review is recorded below; Phase 2 is now
documented in [architecture](architecture.md). The owner has since approved
the design for Build; deployment remains separately gated.

## Owner review: 5 November 2026

- The Arc machines are deliberately powered off, not unexpectedly disconnected.
  They can be started for live checks, validation and demonstration; they do not
  need to be on for documentation or local Build work.
- Focus workspace selection on the nominated existing Arc workspace, excluding
  MCAPS and default workspaces. A read-only follow-up confirmed this is already
  the destination for both monitored servers, with 30-day retention and a
  supported CTI region. Keep actual IDs and customer values in private evidence
  and deployment parameters.
- Existing security roles or collections may be removed to avoid PoC confusion.
  Prepare an exact, dependency-checked cleanup/cutover list before deployment;
  no broad RBAC purge, shared-resource deletion or Azure modification has run.
- Do not introduce deprecated agents, features or toolsets. The Design excludes
  deprecated VM Insights Map and Dependency Agent, in addition to legacy MMA
  and Automation-based Change Tracking.
- Keep attributable PoC running costs within a provisional US$200/month budget.
  Seek confirmation before any higher-cost plan. The detailed estimate, its
  exclusions and spend controls are in [architecture](architecture.md).

## What exists

| Surface | Observed configuration |
| --- | --- |
| Windows Arc estate | 3 servers, all reporting **Disconnected**. OS, Arc agent version and last status change are populated in JSON and CSV. |
| AMA and Change Tracking | Both extensions report successful provisioning on 2 servers. Neither extension was observed on the remaining server. Provisioning does not prove current operation. |
| Dependency Agent / legacy MMA | Neither extension was observed on any of the 3 servers. Guest-installed MMA cannot be excluded by control-plane discovery. |
| DCRs | 6 existing rules across the approved scope. The 2 extension-equipped servers have 3 and 2 associations respectively; the remaining server has none. |
| Performance and events | 1 server has an associated performance/event rule. Both extension-equipped servers have Change Tracking and SQL assessment rules. Preserve the unrelated SQL assessment collection. |
| Workspaces | 7 existing workspaces, all reporting 30-day retention and a pay-as-you-go SKU. The associated rules on both monitored servers route to the same existing workspace. |
| Solutions and Automation | 1 ChangeTracking solution and 2 SecurityCenterFree solutions. No Automation accounts or workspace linked services were returned in the approved scope. A solution alone does not establish active legacy collection. |
| VM Insights | No VMInsights solution, Dependency Agent extension or classic VM Insights DCR candidate was observed on the discovered servers. This is not a guest-health or ingestion assessment. |
| Alerts and Action Groups | 1 enabled metric alert and 4 Action Groups. No scheduled-query or activity-log alert rules were returned. The metric alert has no explicit server/workspace ID match and remains unresolved for review, not confirmed irrelevant. |
| Policies | 12 distinct assignments, with 231 unique initiative/member definitions read. Broad security initiatives are present. Text-based monitoring candidates are not evidence of an effective AMA, DCR or Change Tracking deployment policy. |

## Gaps, conflicts and duplicates

1. **Connectivity is required for live validation, not a current fault.** All 3
   resources report disconnected with late-October status changes. The owner
   confirmed intentional shutdown. Arrange power-on of the named test server
   before live pre-deployment checks and validation. No guest recovery was attempted.
2. **Monitoring coverage is inconsistent.** One server lacks observed extensions
   and associations. Another has Change Tracking and SQL assessment rules, but
   no associated performance/event rule.
3. **Existing collection does not exactly match the requested baseline.** The
   associated performance/event rule samples most counters every 600 seconds
   and a network counter every 60 seconds. It includes System warnings but not
   Application warnings. Its disk counter spelling/format needs validation
   against the guest counter catalogue before claiming disk coverage.
4. **Security collection is already enabled in an existing rule.** This differs
   from the proposed PoC's optional, off-by-default Security collection. Review
   ownership, permissions, privacy and ingestion cost; do not disable, overwrite
   or duplicate the existing rule without explicit approval.
5. **Multiple associations are not proof of duplicates.** The observed
   associations serve performance/events, Change Tracking and SQL assessment.
   Review selectors, intervals, streams, transformations and destinations before
   adding any collection. Each monitored server has one Change Tracking DCR
   candidate; no second CTI candidate was observed for either server.
6. **Legacy Change Tracking is not established.** The ChangeTracking solution
   exists, but no Automation account, workspace Automation link or MMA extension
   was observed. Do not classify the solution as active Automation-based tracking
   or remove it on that evidence alone.
7. **Alert and policy intent still needs owner review.** Retain the unresolved
   metric alert and all Action Groups. Inspect assignment parameters, scopes,
   exclusions, exemptions and any Defender-managed onboarding before proposing
   deployment policies or alerts.

All collection checks succeeded, but RBAC-filtered visibility, Resource Graph
eventual consistency and configuration-only evidence still limit conclusions.
Ingestion, guest service health and effective policy compliance remain untested.

## Workspace reuse

**Reuse is recommended; a new workspace is not currently justified.** Start by
assessing the existing destination shared by the two monitored servers, which
also has the ChangeTracking solution. Its resource ID remains in private
evidence, not in source code or this document.

Confirm region suitability, ownership, access control, private networking, data
residency, retention, pricing tier, capacity and permission to use it for the PoC
with the owner before final selection. Do not create a workspace merely because
its suitability is not yet confirmed.

## Recommended next steps

1. Review the latest JSON report, CSV and private summary with the owner; the
   final run has 298 successful checks and no failed checks.
2. Confirm that all 3 disconnected servers are intended PoC targets and identify
   the named test server. Any recovery or configuration change requires approval.
3. Use the nominated existing Arc workspace as the preferred reuse candidate;
   verify remaining data-handling/access checks and prepare a scoped security
   collection cleanup list without changing shared resources.
4. The owner has approved the [Phase 2 architecture and cost model](architecture.md)
   for Build. Obtain separate deployment approval before Azure changes.
   No Bicep, what-if, deployment or guest changes were performed during
   Discovery or Design.

## Local validation

- Eight isolated mocked-CLI scenarios passed: complete inventory, empty estate,
  extension read denial, resource-list denial, missing graph continuation,
  repeated graph token, untrusted ARM continuation URL and missing dependency.
- Tests cover multi-page Resource Graph results, inherited initiative/member
  reads, endpoint-only associations, alert references, JSON/CSV outputs and
  explicit incomplete-report failures. Tests do not contact Azure.
- PSScriptAnalyzer completed across all PowerShell under `scripts/` and `tests/`
  with no warnings or errors.
- The initial live run exposed Azure CLI's rejection of built-in policy IDs by
  `az resource show`. The collector now uses dedicated policy definition readers;
  the successful rerun supersedes that retained, incomplete report.

## Evidence handling and interpretation

Each run writes JSON, CSV and a private markdown summary beneath the ignored
`scripts/discovery/output/` directory. This tracked document is deliberately not
overwritten by the collector. Reports may contain sensitive infrastructure
metadata, public extension settings, policy parameters, log alert queries,
webhook destinations and notification contact details. Restrict access, retain
only as long as needed, and do not commit, attach or publish raw evidence.
An ignore rule is not encryption or access control.

Discovery only reads configuration: it creates no Azure resources, installs no
agents, enables no collection and sends no notifications. It does not query
guest logs or establish ingestion health. Guest inventory and scheduled change
detection must be validated in later approved phases; Resource Graph is Azure
resource inventory, not SCCM-style guest hardware inventory.

## Microsoft Learn verification

Sources checked on 5 November 2026 using Microsoft Learn directly. The
Microsoft Learn MCP server was not exposed in this session; it is not claimed
as used. To enable it, follow the
[Microsoft Learn MCP installation guide](https://github.com/MicrosoftDocs/mcp/blob/main/README.md).

| Surface | Verified source and use |
| --- | --- |
| Resource Graph | [Arc sample queries](https://learn.microsoft.com/en-us/azure/azure-arc/servers/resource-graph-samples), [CLI reference](https://learn.microsoft.com/en-us/cli/azure/graph#az-graph-query), [paging](https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/work-with-data). Query `Resources` for `microsoft.hybridcompute/machines`, retain `id`, sort and follow continuation tokens. |
| Machine properties | [Machines GET, 2025-01-13](https://learn.microsoft.com/en-us/rest/api/hybridcompute/machines/get?view=rest-hybridcompute-2025-01-13). OS, agent version, status and last status change are control-plane properties; missing values remain unknown. |
| Extensions | [Machine extensions LIST, 2025-01-13](https://learn.microsoft.com/en-us/rest/api/hybridcompute/machine-extensions/list?view=rest-hybridcompute-2025-01-13), [Arc extensions](https://learn.microsoft.com/en-us/azure/azure-arc/servers/manage-vm-extensions), [AMA management](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-manage). Match publisher/type, not the user-chosen resource name; report returned handler and instance versions, without pinning a deployment version. |
| AMA/Dependency Agent | Arc extension reference identifies `Microsoft.Azure.Monitor / AzureMonitorWindowsAgent` and `Microsoft.Azure.Monitoring.DependencyAgent / DependencyAgentWindows`. These are discovery flags, not installation instructions. |
| Change Tracking | [Current overview](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/overview-monitoring-agent), [onboarding](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/quickstart-monitor-changes-collect-inventory-azure-change-tracking-inventory). Detect `Microsoft.Azure.ChangeTrackingAndInventory / ChangeTracking-Windows`; retain existing public CTI settings and DCR payloads. Version guidance must be rechecked during Design. |
| CTI DCR interpretation | [Create a CTI DCR](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/create-data-collection-rule) and its [linked sample](https://learn.microsoft.com/en-us/azure/automation/change-tracking/change-tracking-data-collection-rule-creation) identify the Windows extension data source and configuration streams. Only one CTI DCR is used per resource; preserve the dedicated rule rather than adding unrelated data sources. The linked sample is under the Automation documentation path but explicitly describes the AMA DCR; that URL does not imply legacy Automation onboarding. |
| Legacy MMA identification | [Archived Windows extension schema](https://learn.microsoft.com/en-us/previous-versions/azure/virtual-machines/extensions/oms-windows) documents `Microsoft.EnterpriseCloud.Monitoring / MicrosoftMonitoringAgent`. Used only to identify legacy configuration, never to deploy it. [Current migration guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-migration) confirms retirement and ingestion shutdown risks. |
| DCR associations | [LIST by resource, 2024-03-11](https://learn.microsoft.com/en-us/rest/api/monitor/data-collection-rule-associations/list-by-resource?view=rest-monitor-2024-03-11). Learn redirected the initially requested 2023 moniker to 2024-03-11; the script uses the explicitly documented version, not the requested moniker. |
| Resource configuration | [Resource list/show](https://learn.microsoft.com/en-us/cli/azure/resource). Enumerate then GET full resource details, including DCR data sources, destinations and flows, workspace SKU/retention, solution workspace links and full alert definitions. API selection for `resource show` is delegated to Azure CLI's latest stable provider version; no unverified version literal is supplied. |
| Legacy Automation links | [Workspace linked services, 2020-08-01](https://learn.microsoft.com/en-us/rest/api/loganalytics/linked-services/list-by-workspace?view=rest-loganalytics-2020-08-01). Combine links with solution evidence; a link alone does not establish active legacy Change Tracking. |
| Policies | [Assignment list](https://learn.microsoft.com/en-us/cli/azure/policy/assignment#az-policy-assignment-list), [definition show](https://learn.microsoft.com/en-us/cli/azure/policy/definition#az-policy-definition-show) and [initiative show](https://learn.microsoft.com/en-us/cli/azure/policy/set-definition#az-policy-set-definition-show). Include parent and child scopes. Read definitions by name with explicit subscription/management-group context, verify the returned ID, and expand initiative members. These CLI policy payloads have top-level properties rather than ARM's `properties` envelope. |
| VM Insights | [Current VM monitoring enablement](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/vm-enable-monitoring). Learn now describes both OpenTelemetry and classic logs-based experiences. Preserve all DCR definitions; classic VM Insights/Change Tracking string matches are candidates, not a complete health assessment. Do not silently substitute a new monitoring architecture for the requested PoC. |

No Log Analytics guest query, ingestion estimate, deployment extension version or
resource deployment is introduced in Phase 1. The [Phase 2 design](architecture.md)
records separately verified table/column schemas, pricing, licensing and
collection limits; live behaviour and actual costs still require validation.
