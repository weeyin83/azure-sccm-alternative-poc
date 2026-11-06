# Query library: Build in progress

The `.resource-graph.kql` files run with Azure Resource Graph, which reports
Azure resource inventory and configuration. It does not provide SCCM-style
guest hardware inventory. Other files run in the nominated Log Analytics
workspace and report guest data. DCR associations are in Resource Graph's
`insightsresources` table, not `Resources`; visibility is still RBAC-filtered
and eventually consistent. The resource-type reference calls this table
`insightresources`, but Microsoft's example uses `insightsresources`. Confirm
associations with the per-machine ARM list before deployment.
On 6 November 2026 a read-only aggregate from the corrected query matched the
prior discovery totals (three servers, two with associations, five
associations). This does not establish current guest health or guarantee that
Resource Graph will remain in sync with ARM.

Most Log Analytics queries use an empty `ServerIds` list until approved Arc
resource IDs are supplied for a session; an empty list returns no results. Do
not commit customer IDs. The heartbeat query starts from an expected-server
datatable with the start of each current expected-online period. It applies a
15-minute onboarding grace and reports absence within its one-day lookback;
absence is not proof that the server has never reported. Include only machines
explicitly expected online for that interval; exclude powered-off or maintenance
periods even when Arc reports Connected. `Heartbeat` can include agents other
than AMA, so a heartbeat alone does not establish AMA health.

The expected-service query takes explicit server/service pairs, reconciles
inventory with later changes independently for state and start type, and
reports missing, conflicting or stale state as unknown rather than healthy.
Its one-hour freshness threshold is conservative: unchanged services may not
produce a new observation within that period. Unknown is not proof of failure.

The heartbeat and expected-service queries use literal `ago()` arguments,
as required for log search alert queries. This alone does **not** make them
deployable alert definitions. An alert's configured query range must cover the
query's history (one day for heartbeat and two days for services), and its
expected-online list, unknown states, automatic resolution, dimensions and
notification behaviour must be reviewed and tested. A longer query range can
increase query costs. See the [alert query limitations](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
and [scheduled query rule schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/2023-12-01/scheduledqueryrules).

## Draft alert query templates

These are candidates for the eight rules in the architecture, not approved
deployment parameters. All expected-server, volume, event and item lists are
empty by default. **An empty list produces no alert; it is not evidence that
the estate is healthy.** A complete preflight must reject an enabled rule with
an empty or invalid scope. Edit a private copy only after scope and baseline
review; do not commit IDs, software baselines or watched paths.
Each query is self-contained; no shared KQL functions are deployed to the
workspace.

A [private parameter generator](../docs/deployment.md#prepare-review-only-alert-parameters)
can render these eight candidates using explicit selected servers and baselines.
Its files remain review-only and do not establish safe alert recovery or
deployment readiness.

| Candidate | Query | Initial signal and limitations |
| --- | --- | --- |
| CPU | [high-cpu.kql](alerts/high-cpu.kql) | Mean of at least three distinct valid samples above 90% in 15 minutes; no sample in the last five minutes, insufficient samples or conflicting values are unknown. |
| Memory | [low-memory.kql](alerts/low-memory.kql) | Mean of at least three distinct valid `Available MBytes` samples below 500 in 15 minutes; missing, stale or conflicting samples are unknown. It is not physical-memory percentage. |
| Disk | [low-disk-space.kql](alerts/low-disk-space.kql) | Both free space below 10% and `Free Megabytes` below 5,120 on a privately nominated volume. Both samples must be recent and within two minutes of one another; absent or conflicting counters are unknown. `Perf` alone does not distinguish fixed disks. |
| Critical events | [critical-windows-events.kql](alerts/critical-windows-events.kql) | Level 1 System/Application events from explicitly nominated source and event-ID combinations in ten minutes. Errors remain available in the event query. |
| Service | [services-expected-running.kql](services-expected-running.kql) | Returns stopped and unknown expected services; do not filter unknown out and then treat an aged-out stopped observation as recovery. |
| Software | [unexpected-software.kql](alerts/unexpected-software.kql) | Software additions in one hour outside the exact per-server name/publisher allowlist. An incomplete software identity is not silently allowed. |
| Registry/file | [configuration-changes.kql](alerts/configuration-changes.kql) | Any change in two hours to the exact nominated registry values or files, including planned changes. Review how to handle an authorised test before enabling notifications. |
| Heartbeat | [heartbeat-missing.kql](heartbeat-missing.kql) | Missing or stale evidence for explicitly expected-online servers; the absence is limited to the available one-day history. |

The performance templates' five-minute freshness assumes the proposed
60-second collection interval and must be retuned for an existing slower DCR
or ingestion delays. Unknown does not prove a server is unhealthy. Event and
change templates only report matching recent records: when a stateful alert
resolves after the event ages out, that does not prove the underlying issue or
configuration was fixed. No-data conditions for these event-based signals
need separate monitoring. The templates omit event content and registry values
from their output, but embedded paths, allowlists and IDs in an alert rule are
still sensitive configuration stored in Azure Resource Manager. Alert
evaluation, extra time series and queries can incur charges.

These are draft queries and have not been executed against live records. In
particular, review the actual CTI `ConfigDataType`, service inventory freshness,
resource IDs and counter names after deployment approval. CTI collection is
scheduled: absence of a change is not proof that it did not occur. A latest
inventory record is not a real-time state guarantee. The software reconciliation
window is 30 days; extend only after checking workspace history and cost.
Software identity is grouped by server, name and publisher because change
records do not expose an installed version. An addition can therefore have a
blank version; same-named products cannot always be distinguished, and
conflicting observations at the latest timestamp are shown as unknown. Records
older than one day are marked stale; a recent observation is not a guarantee of
current state. CTI can mark user-level applications removed when the user signs
out, so investigate before interpreting every removal as an uninstall.

Empty-scope checks and synthetic fixtures can run as read-only queries in an
existing workspace; they return no customer records. They exercise alert
thresholds and averages, missing and conflicting samples, Windows event and
configuration filters, software, service and heartbeat cases. The tests do not
validate actual guest data or Azure alert evaluation and recovery. Checks
against real workspace records remain outstanding.

Sources checked against Microsoft Learn:
[Resource Graph Arc samples](https://learn.microsoft.com/en-us/azure/azure-arc/servers/resource-graph-samples),
[Resource Graph table/resource mapping](https://learn.microsoft.com/en-us/azure/governance/resource-graph/reference/supported-tables-resources),
[Microsoft's Resource Graph DCR association example](https://github.com/MicrosoftDocs/azure-docs/blob/main/articles/governance/includes/resource-graph/samples/query/insight-resources-monitor-data-collection-rules.md),
[Perf](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/perf),
[Event](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/event),
[ConfigurationData](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/configurationdata),
[ConfigurationChange](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/configurationchange),
[Heartbeat](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/heartbeat),
[CTI support matrix](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/change-tracking-inventory-support-matrix).
[CTI overview and user-level software caveat](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/overview-monitoring-agent).
