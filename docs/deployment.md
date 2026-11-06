# Build status and proposed cutover

**Build is incomplete. Do not deploy the individual modules.** The owner has
approved the design, but has not approved deployment, cleanup or guest changes.
The nominated existing `arc-loganalytics` workspace is the only workspace
candidate; do not select MCAPS/default workspaces or change their configuration.

The draft [subscription-scope entry point](../infra/main.bicep) invokes
independently scoped modules in separate stages, with empty operation lists by
default and newly created alerts and Action Groups disabled. AMA and CTI
extensions use distinct `ama` and `change-tracking-extension` stages; the
previous draft `agents` stage is no longer accepted. This separation does not
automatically enforce the required health checks between stages. Collection
rules and associations are also separate stages. The entry point accepts only
an existing workspace ID and does not create or modify a workspace.

The independent modules currently cover a Windows performance/event DCR, a
dedicated Windows CTI DCR, AMA and CTI Arc extensions, DCR associations, an
email Action Group and a workspace-scoped scheduled query alert. Notifications
and alert rules default to disabled. The modules do **not** check for existing
resources or prevent overwriting one with the same name. The entry point does
not validate scope consistency, existing names, duplicate collection or alert
intent, nor does it perform an association cutover. A reuse-first
preflight/cutover tool and reviewed parameters are still required. Compilation
is not permission or evidence that these modules are safe to deploy. The
remaining core components and validation are listed in the README.

The generic log-alert module requires an explicit query history, automatic
resolution choice and per-resource splitting choice. A query history shorter
than the query's own lookback can discard evidence even when the evaluation
window is shorter. For example, the draft service view looks back two days and
the heartbeat view one day. The partial plan review flags history shorter than
the alert window or a simple literal `ago()` lookback, and flags empty literal
data lists. It is not a KQL parser and cannot prove that the configured history
and scope are complete or that recovery behaviour is safe. Automatic resolution can otherwise
look like recovery when data is missing; stateless rules can notify repeatedly.
Splitting by `ResourceId` adds billable time series. All of these choices need
review and controlled validation before enabling an alert.

## Itemised cleanup and cutover proposal

This is a proposal, not an instruction to perform changes. The discovery report
is private and may contain sensitive IDs and receiver details. A final manifest
must identify each exact resource ID, owner, other consumers, existing settings,
replacement, action, rollback and explicit approval. Refresh discovery and
compare it with the private report before finalising the manifest.

The [review generator](../scripts/discovery/New-ArcCutoverReview.ps1) can
produce a Git-ignored, owner-only inventory from a complete discovery report
less than an hour old. Each input report, optional baseline and optional stage
parameter file must be a real, single-link, owner-only file in a dedicated, Git-ignored
`scripts/discovery/output/` subdirectory; Git must also confirm it is untracked.
On Linux and macOS both evidence directories must be owned by the current user
with mode `700`, and the input files must be owned by that user with mode `600`.
Stage parameters are limited to 2 MiB and JSON fields must be unique regardless
of case. Input privacy and hashes are checked again before the review is
written, but cannot eliminate concurrent changes. The Windows ACL path still
requires Windows testing. The review records DCR properties, selected-server
associations and alert criteria, and marks existing resources for preservation.
It counts Action Group receivers without copying their destinations. The
source-report hash helps identify which snapshot was reviewed.

**This is not the final cutover manifest or a deployment preflight.** Owners,
other consumers, proposed replacements, actual parameter changes and rollback
approvals remain unconfirmed. With an optional literal ARM parameter JSON
file, it flags existing resource names, possible category-level collection
overlap and alerts or Action Groups needing review. This is not a complete
selector or alert-intent comparison, a live-state check or guest-health
assessment. It always reports `ReadyForWhatIf = false` and
`ReadyForDeployment = false`. Do not treat `ReviewRequired` as approval to run
what-if or deploy. Keep the report, parameters and generated review file private
and never force-add them to Git.

For proposed associations, the review checks literal counter and XPath
selectors, input streams and workspace destinations against existing and
same-stage associations. It also compares recorded sampling intervals,
inline transformations and output streams when possible. Overlapping XPath
expressions, wildcard counters, named transformations, other destinations and
unreadable configuration still require manual review; an absent literal match
does not prove that collection is distinct. See Microsoft's
[DCR structure](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-rule-structure)
and [DCR samples](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-rule-samples).

The optional baseline comparison identifies changes in captured server,
resource, workspace and policy evidence, including DCR settings, alert criteria
and Action Group receivers without copying receiver destinations into the
review file. The current discovery collection must have started within 15
minutes. This is still an offline snapshot comparison: it cannot establish
complete visibility, guest health or effective policy and remediation, and
`NoDriftObserved` does not permit what-if or deployment.

### Prepare review-only alert parameters

[New-ArcAlertParameters.ps1](../scripts/deployment/New-ArcAlertParameters.ps1)
renders any of the eight draft alert candidates into a literal ARM parameter
file. It reads a complete discovery report less than one hour old and makes no
Azure calls. It does **not** create or enable alerts, establish equivalence with
existing alerts, verify guest health or determine that what-if is safe.

The report and configuration must each be a real, single-link, owner-only file in a
dedicated, Git-ignored `scripts/discovery/output/` subdirectory. On Linux and
macOS, both directories must be owned by the current user with mode `700`, and
both files must be owned by that user with mode `600`. Git must confirm each
file is ignored and untracked. On Windows, the corresponding owner-only ACL
checks still require Windows testing. The generated parameter and review files
are created in a new protected output directory. Neither file should be
force-added to Git.

To prepare a private, initially empty configuration file:

```powershell
Import-Module ./scripts/discovery/ArcPrivateEvidence.psm1
$discoveryDirectory = (Resolve-Path ./scripts/discovery).Path
$privateConfigDirectory = New-ArcPrivateEvidenceDirectory `
    -DiscoveryDirectory $discoveryDirectory `
    -DirectoryName ('alert-configuration-' + [guid]::NewGuid().ToString('N'))
$privateAlertConfigPath = New-ArcPrivateEvidenceFile `
    -Directory $privateConfigDirectory -FileName 'configuration.json'
```

Edit the file in a private editor, replacing the placeholders below. The
approved workspace and server IDs are supplied separately from the private
discovery report. Do not enter these values into a tracked file, shared shell
history or chat. Editors that replace files can change permissions; the
generator rejects an insecure file rather than repairing it.

```json
{
  "schemaVersion": "1.0",
  "scope": {
    "subscriptionId": "<enumerated-subscription-id>",
    "resourceGroupName": "<alert-resource-group>"
  },
  "location": "<azure-region>",
  "tags": {},
  "actionGroup": {
    "mode": "existing",
    "resourceId": "<discovered-approved-action-group-id>"
  },
  "alerts": [
    {
      "kind": "cpu",
      "name": "<unique-alert-name>",
      "displayName": "Sustained high CPU",
      "description": "Review sustained CPU and missing evidence.",
      "evaluationFrequency": "PT5M",
      "windowSize": "PT15M",
      "queryTimeRange": "PT15M",
      "autoMitigate": false,
      "splitByResourceId": true,
      "severity": 2,
      "datasets": {
        "ExpectedServers": [{ "ResourceId": "<approved-arc-server-id>" }]
      },
      "thresholds": { "ThresholdPercent": 90.0 }
    }
  ]
}
```

This is a starting point for review, **not** an approved alert. The permitted
`kind` values are unique within a configuration. Every listed dataset must
contain 1–100 rows and every `ResourceId` must match one of the explicitly
selected Arc servers. Fields are named exactly as follows:

| Kind | Required `datasets` and row fields | Required `thresholds` | Minimum `queryTimeRange` |
| --- | --- | --- | --- |
| `cpu` | `ExpectedServers`: `ResourceId` | `ThresholdPercent` (0–100) | `PT15M` |
| `memory` | `ExpectedServers`: `ResourceId` | `ThresholdMBytes` (0–1,000,000,000) | `PT15M` |
| `disk` | `ExpectedVolumes`: `ResourceId`, `Volume` | `ThresholdPercent` (0–100), `ThresholdMBytes` (0–1,000,000,000) | `PT15M` |
| `events` | `ExpectedEvents`: `ResourceId`, `EventLog`, `Source`, `EventID` | `{}` | `PT10M` |
| `service` | `ExpectedServices`: `ResourceId`, `SvcName` | `{}` | `P2D` |
| `software` | `ExpectedServers`: `ResourceId`; `AllowedSoftware`: `ResourceId`, `SoftwareName`, `Publisher` | `{}` | `PT1H` |
| `configuration` | `RegistryItems`: `ResourceId`, `Hive`, `RegistryKey`, `ValueName`; `FileItems`: `ResourceId`, `FileSystemPath` | `{}` | `PT2H` |
| `heartbeat` | `ExpectedServers`: `ResourceId`, `ExpectedOnlineSince` | `{}` | `P1D` |

`EventLog` is System or Application, and `EventID` is an integer from 0 to
65,535. Every expected software server needs at least one allowlist row; an
allowlist cannot include a server outside that alert's expected list. Both
registry and file lists are required for the combined configuration candidate.
The registry hive must be `HKLM` or `HKEY_LOCAL_MACHINE`; `ValueName` may be
empty for the default value. All item names must match the values actually
observed in CTI records, including the hive representation. `ExpectedOnlineSince`
must include a UTC offset and must not be in the future. Review that timestamp
after every maintenance or deliberately offline period.

The CPU, memory and disk templates currently use a 15-minute history and a
five-minute freshness cutoff; CPU and memory require three samples. Tune these
templates and revalidate the renderer before using an existing slower DCR.
The input's alert window and query history are separately specified; history
must cover both the window and the template's longest lookback. For the
performance, event, software and configuration candidates, the window must
also cover the template's lookback. Service and heartbeat intentionally use
longer histories than their evaluation windows. The generator also rejects
duplicate rows, invalid timings, missing baselines and resource names already
observed in discovery. It does not interpret arbitrary KQL.

An alternative `actionGroup` object can propose a new group when no existing
group is suitable:

```json
{
  "mode": "new",
  "name": "<unique-action-group-name>",
  "groupShortName": "<up-to-12-characters>",
  "emailReceivers": [{ "emailAddress": "<approved-address>" }]
}
```

The group and any new alerts are **disabled in the draft Bicep stage**. Creating
a group still requires a review of existing groups, recipients, ownership and
cost; merely generating the parameter file changes nothing in Azure. The
generator uses one Action Group for all alerts in a parameter file.

After editing the private configuration:

```powershell
./scripts/deployment/New-ArcAlertParameters.ps1 `
    -ReportPath $privateReportPath `
    -ConfigurationPath $privateAlertConfigPath `
    -WorkspaceResourceId $approvedWorkspaceResourceId `
    -ServerResourceId $approvedArcServerResourceIds
```

Review the two output paths locally. The review records source and parameter
hashes and findings, not query text or receiver addresses. It always reports
`ReadyForWhatIf = false` and `ReadyForDeployment = false`; also pass the
generated parameters to the [private cutover review](../scripts/discovery/New-ArcCutoverReview.ps1)
and complete all remaining gates. Refresh discovery immediately before any
eventual what-if. A generated parameter file is plain text and contains private
IDs, query scopes and possibly recipients; Azure Resource Manager would also
store alert query configuration if later deployed. Do not include passwords,
tokens or other secrets in it. Alert evaluation and per-series dimensions can
incur charges.

References: [ARM parameter files](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/parameter-files),
[KQL datatable](https://learn.microsoft.com/en-us/kusto/query/datatable-operator),
[KQL string literals](https://learn.microsoft.com/en-us/kusto/query/scalar-data-types/string),
and [log search alert query limitations](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule).

### Proposed dispositions

| Item | Proposed disposition | Dependencies and rollback |
| --- | --- | --- |
| Nominated Arc workspace and ChangeTracking solution | Reuse unchanged. Do not create another workspace or alter retention, network settings or caps. | Confirm access, region, licensing and data handling. Never delete or roll back the shared workspace. |
| Existing performance/event DCR and its association on one server | The 6 November refresh confirms one association. It collects performance and event streams and includes Security. Inspect all consumers and exact selectors. If unsuitable, create a separate PoC rule and cut over only the approved target association; do not overwrite or delete the shared DCR. | Record exact old and new IDs and settings; restore the original association if rollback is approved. Avoid overlap in identical collection. |
| Existing Security event selector | Determine ownership, consumers, privacy requirements and ingestion cost. No removal is assumed. | Removing the association may also remove Security events for the target; separately approve any change and preserve required coverage. Restore the recorded association on rollback. |
| Existing CTI rules and associations on two servers | Compare settings with requirements and reuse if suitable. Otherwise prepare a dedicated PoC CTI rule and switch each approved association, never adding a second CTI DCR to a server. | Save previous associations and settings. Restore them on rollback; do not modify shared CTI rules in place. |
| Existing AMA and CTI extensions on two servers | Reuse the provisioned extensions. At 10:10 UTC on 6 November, both reported AMA 1.45.0.0 and CTI 2.42.0.0; one CTI version had changed since the earlier snapshot. Their reported provisioning state is not health evidence. Do not reinstall under a different name or downgrade. | Investigate the observed drift and recheck extension instance view, AMA heartbeat and CTI data after selecting a test server. Do not remove extensions used by other workloads. |
| Server with no observed extensions or associations | Recheck control-plane and guest state before proposing new extensions and associations. | Only remove extensions installed specifically for the PoC if no other consumers remain and removal is approved. |
| Existing SQL assessment rules and associations | Preserve unchanged. | No cleanup action proposed. |
| Existing metric alert and Action Groups | Inspect scope, query/criteria, recipients and ownership; reuse suitable configuration and avoid equivalent alerts. | Do not delete, overwrite or send test notifications without approval. Restore any explicitly approved changes. |
| Policy assignments, RBAC and security services | Inspect effective assignments, exemptions and remediation ownership; preserve by default. | No role, Defender, Sentinel or policy removal is proposed. Any later change needs a separate exact dependency review and approval. |

All three Arc resources reported Connected in the 6 November 2026 read-only
refresh. This does not establish guest or monitoring health. Select the named
test server and obtain any required guest-change approval before live checks.
No guest changes are authorised by this document.

## Validation and cost gates

Complete orchestration, safe preflight, parameters, queries, alert rules and
the required validation of the draft demo script before running a target-scope what-if.
The owner has deferred test-application installation. Review the
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
- [Log search alert Bicep examples with a regional location](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/resource-manager-alerts-log)

The Action Group uses `global`, but the scheduled-query alert module requires
an explicit Azure region. Confirm that region and the workspace relationship
before deployment; a successful Bicep build does not verify regional support.

The CTI sample's Windows file interval is 2,700 seconds, whereas the current
support matrix lists 1,800–2,400 seconds. The module uses the support matrix's
range; validate actual behaviour before extending the PoC. One existing rule
also records the sample's 2,700-second value and no file-item list in the
captured Windows settings. The existing rule must not be changed merely to
match the draft. The sample uses `fileinfo` and the Linux sample uses `fileInfo`;
the generic DCR Bicep schema leaves `extensionSettings` untyped. Confirm the
accepted Windows field shape against current service behaviour before
deployment. The draft's 36,000-second inventory setting is present in the
Microsoft sample, but the support matrix says only Windows file and service
frequencies are customisable. No guest or service-side validation has been
performed.
