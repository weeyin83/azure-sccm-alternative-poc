# Validation plan and current evidence

**Build is incomplete. Deployment and guest changes have not been approved or
performed.** This document records checks already made and the checks required
after a separate deployment approval. A completed local build is not proof of
Azure deployment or monitoring health.

## Evidence collected during Build

| Check | Result | Boundary |
| --- | --- | --- |
| Arc control-plane connectivity | Three resources reported Connected in the 6 November 2026 refresh. | Connection status does not establish guest or AMA health. |
| Existing extensions and associations | Two servers reported successfully provisioned AMA and Change Tracking extensions. Five DCR associations were observed across those servers; the third had none. | Provisioning and associations are configuration evidence, not proof of continuous collection. Preserve existing SQL assessment and Security collection pending review. |
| Recent workspace data | A read-only, 24-hour aggregate found Heartbeat for 2 of 3 servers, Perf and Event for 1 of 3, and ConfigurationData and ConfigurationChange for 2 of 3. | A heartbeat can be produced by an agent other than AMA; an absent event alone is not a fault. See [discovery findings](discovery-findings.md). |
| Bicep | Local build and lint passed for the draft entry point and modules; eight infrastructure contract tests passed. Alert history, resolution and resource splitting are explicit inputs. | No target-scope what-if has been run. These checks do not prevent overwrites or establish that a deployment is safe. |
| PowerShell | Mocked discovery, telemetry, private-review, alert-parameter, literal DCR overlap, snapshot-drift and staged demo recovery tests passed; PSScriptAnalyzer returned no warnings or errors. Private journal creation and locking were tested locally. | The comparison and generated parameters are not a complete preflight. One CTI extension version changed between snapshots; investigate before planning. Windows guest operations and Windows ACLs remain untested; no demo or guest change was executed. |
| Query library | Nineteen contract and synthetic/empty-scope tests passed, including all eight generated alert queries, mean CPU/memory values, threshold boundaries, missing/conflicting samples, Windows paths, bounded heartbeat history and service state reconciliation. The read-only query fixtures used the existing workspace and Resource Graph; partial API responses are rejected. | These do not validate query results against actual guest records or an Azure alert evaluation. Queries can incur service charges. |
| PoC alerts and Workbooks | Not deployed or tested. The discovered existing metric alert is preserved. | Workbooks are stretch scope. |

Keep raw reports, resource IDs, recipients and diagnostic evidence in the
ignored private output directory, not in this document or Git. Record only
sanitised results here.

## Gates before what-if

1. Finish the Build, including a complete fail-closed reuse and overlap
   preflight, staged deployment tooling, alert definitions and Windows testing
   of the draft demo automation. Test-application installation is deferred.
   The [private cutover review](deployment.md#itemised-cleanup-and-cutover-proposal)
   is an inventory and partial plan comparison, **not** that preflight.
2. Select an owner-approved test server and review the current workspace,
   extension health, policies, exact DCR selectors and destinations,
   associations, alert intent and Action Group recipients. Confirm ownership
   and other consumers; preserve existing resources by default.
3. Prepare private stage parameters and an itemised cutover/rollback manifest.
   Refresh discovery immediately before evaluating the plan. Confirm the
   Change Tracking DCR file-setting shape and supported frequencies.
4. Confirm the provisional US$200/month target against existing attributable
   costs, expected ingestion, alert pricing and applicable licensing. Obtain
   approval before proposing a higher-cost plan.
5. Only when the preflight and private parameters have been reviewed, run a
   target-scope what-if and review each create, modify and delete result. A
   what-if is not deployment approval; obtain that approval separately.

## Post-approval validation

Perform these checks incrementally on the named test server before extending
the PoC. Guest actions and test notifications require their own explicit
approval. If any gate fails, stop and follow the approved rollback plan rather
than layering on another DCR or extension.

| Gate | Evidence to collect | Pass condition |
| --- | --- | --- |
| Arc and AMA | Confirm expected-online status, actual extension instance and guest/data-path health using current [AMA troubleshooting guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-arc). | Arc is connected and AMA is healthy on the approved host; a heartbeat alone is not sufficient. |
| DCRs and associations | Re-read the exact associations and DCR definitions through ARM; inspect selectors, streams, transformations and destinations. | Intended data reaches the nominated workspace without equivalent overlapping collection; at most one CTI DCR is associated. |
| Heartbeat and performance | Use the scoped [heartbeat](../queries/heartbeat-missing.kql) and [performance](../queries/performance.kql) queries. Check timestamps, expected-online periods and actual guest counter names. | Recent evidence exists for the selected host, and expected CPU, memory and disk series arrive at the reviewed interval. Missing evidence is investigated, not labelled automatically as agent failure. |
| Windows events | Use [windows-events.kql](../queries/windows-events.kql) and, only with approval, generate a designated test event. | A matching event appears in the nominated workspace. A quiet event log alone is not a failure. |
| Change Tracking | Establish a baseline; verify software and services are represented within published limits, and check approved registry and file items. | Expected inventory and subsequently observed changes arrive after their scheduled collection and ingestion delays. Short-lived changes may be missed. |
| Queries | Populate approved server IDs or expected-server/service lists privately and run every applicable [query](../queries/). | Queries return the expected shape and known test results. An empty or stale result is explained; it is not automatically a failure or a healthy state. |
| Alerts | Review existing alert equivalence and approved recipients, then test each enabled rule and recovery with controlled scenarios. | The intended signal fires with acceptable delay and noise; no duplicate notification or false recovery is observed. |
| Workbooks, if separately approved | Open each deployed workbook and test time/server filters and drill-down. | Views render the intended scoped data without extra collection. |
| Demo tooling | On an approved isolated Windows test host, validate local name and privilege guards, owner-only journal ACLs, exact file/registry and service controls, `-WhatIf`, partial-failure recovery and the approved test event. | The reviewed and separately approved actions work and restore safely; software installation is deferred. Do not treat Linux mocks or C# compilation as Windows integration evidence. |
| Cost and rollback | Measure incremental ingestion and alerts after the baseline; test the specifically approved rollback sequence. | Forecast and data handling remain acceptable, shared resources remain intact, and any approved test changes are reversed. |

Record failures and remedies in [troubleshooting](troubleshooting.md), without
customer-identifying data. Collection frequencies and limitations are in the
[architecture](architecture.md#5-collection-baseline).
