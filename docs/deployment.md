# Build status and proposed cutover

**Build is incomplete. Do not deploy the individual modules.** The owner has
approved the design, but has not approved deployment, cleanup or guest changes.
The nominated existing `arc-loganalytics` workspace is the only workspace
candidate; do not select MCAPS/default workspaces or change their configuration.

The independent modules currently cover a Windows performance/event DCR, a
dedicated Windows CTI DCR, AMA and CTI Arc extensions, DCR associations, an
email Action Group and a workspace-scoped scheduled query alert. Notifications
and alert rules default to disabled. The modules do **not** check for existing
resources or prevent overwriting one with the same name. They are not yet wired
to an entry point or a preflight/cutover tool. Compilation is not permission or
evidence that these modules are safe to deploy. The remaining core components
and validation are listed in the README.

## Itemised cleanup and cutover proposal

This is a proposal, not an instruction to perform changes. The discovery report
is private and may contain sensitive IDs and receiver details. A final manifest
must identify each exact resource ID, owner, other consumers, existing settings,
replacement, action, rollback and explicit approval. Refresh discovery and
compare it with the private report before finalising the manifest.

| Item | Proposed disposition | Dependencies and rollback |
| --- | --- | --- |
| Nominated Arc workspace and ChangeTracking solution | Reuse unchanged. Do not create another workspace or alter retention, network settings or caps. | Confirm access, region, licensing and data handling. Never delete or roll back the shared workspace. |
| Existing performance/event DCR and its association on the one covered server | Inspect all consumers and exact selectors. If unsuitable, create a separate PoC rule and cut over only the approved target association; do not overwrite or delete the shared DCR. | Record exact old and new IDs and settings; restore the original association if rollback is approved. Avoid overlap in identical collection. |
| Existing Security event selector | Determine ownership, consumers, privacy requirements and ingestion cost. No removal is assumed. | Removing the association may also remove Security events for the target; separately approve any change and preserve required coverage. Restore the recorded association on rollback. |
| Existing CTI rules and associations on two servers | Compare settings with requirements and reuse if suitable. Otherwise prepare a dedicated PoC CTI rule and switch each approved association, never adding a second CTI DCR to a server. | Save previous associations and settings. Restore them on rollback; do not modify shared CTI rules in place. |
| Existing AMA and CTI extensions on two servers | Reuse suitable versions; establish health when powered on. Do not reinstall under a different name or downgrade. | Record actual extension identities and versions. Do not remove extensions used by other workloads. |
| Server with no observed extensions or associations | Recheck control-plane and guest state before proposing new extensions and associations. | Only remove extensions installed specifically for the PoC if no other consumers remain and removal is approved. |
| Existing SQL assessment rules and associations | Preserve unchanged. | No cleanup action proposed. |
| Existing metric alert and Action Groups | Inspect scope, query/criteria, recipients and ownership; reuse suitable configuration and avoid equivalent alerts. | Do not delete, overwrite or send test notifications without approval. Restore any explicitly approved changes. |
| Policy assignments, RBAC and security services | Inspect effective assignments, exemptions and remediation ownership; preserve by default. | No role, Defender, Sentinel or policy removal is proposed. Any later change needs a separate exact dependency review and approval. |

The deliberately powered-off servers are not a current fault. The owner must
start the named test server for live checks, only after the appropriate
approval. No guest changes are authorised by this document.

## Validation and cost gates

Complete orchestration, safe preflight, parameters, queries, alert rules, demo
script and documentation before running a target-scope what-if. Review the
what-if output and the exact manifest before requesting separate deployment
approval. Do not use complete-mode deployment.

The US$200/month target is provisional, not a spending cap. Confirm
attributable existing charges, licensing, alert pricing and forecast before
deployment. Monitor ingestion and data handling after approval: performance
counters and event messages, software, services and configured registry/file
metadata can contain sensitive operational information. Security events are
not in the default performance/event selectors, but an existing DCR may still
collect them. See [architecture](architecture.md) for estimates and limits.

## Sources checked during Build

- [DCR Bicep resource, API 2024-03-11](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/2024-03-11/datacollectionrules)
- [DCR association, API 2024-03-11](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/2024-03-11/datacollectionruleassociations)
- [Arc extensions, API 2025-01-13](https://learn.microsoft.com/en-us/azure/templates/microsoft.hybridcompute/2025-01-13/machines/extensions)
- [AMA performance and event DCR examples](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-samples)
- [Performance collection and duplicate-counter warning](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection-performance)
- [Windows events and XPath](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/data-collection-windows-events)
- [CTI DCR creation and one-rule constraint](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/create-data-collection-rule)
- [CTI DCR sample and Windows file settings](https://learn.microsoft.com/en-us/azure/automation/change-tracking/change-tracking-data-collection-rule-creation)
- [CTI frequencies and limitations](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/change-tracking-inventory-support-matrix)
- [CTI current extension guidance](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/overview-monitoring-agent)
- [AMA extension support and releases](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-extension-versions)
- [Action Group resource, API 2023-01-01](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/2023-01-01/actiongroups)
- [Scheduled query alert resource, API 2023-12-01](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/2023-12-01/scheduledqueryrules)

The CTI sample's Windows file interval is 2,700 seconds, whereas the current
support matrix lists 1,800–2,400 seconds. The module uses the support matrix's
range; validate actual behaviour before extending the PoC. The sample uses
`fileinfo` and the Linux sample uses `fileInfo`; confirm the accepted Windows
field shape against current service behaviour before deployment. No guest or
service-side validation has been performed.
