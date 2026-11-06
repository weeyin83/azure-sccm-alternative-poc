# Troubleshooting

No Azure configuration or guest changes are authorised by this guide. Start
with read-only evidence and the [current findings](discovery-findings.md).
Before making a change, identify the owner, other consumers, exact resource,
rollback and the approval required. Keep customer evidence and identifiers out
of Git.

| Symptom | Read-only investigation | Important limitation or next gate |
| --- | --- | --- |
| Arc reports disconnected | Confirm the server is expected online, inspect its current Arc status and last status change, and compare with the eventually consistent Resource Graph view. | A planned shutdown is not a fault. Do not power on, restart or re-onboard a host without approval. |
| No heartbeat in the nominated workspace | Check the selected resource ID, expected-online period, query window, workspace access and DCR destination; compare the latest bounded observation. | A missing heartbeat does not identify which agent failed. A present heartbeat can come from an agent other than AMA. Use [AMA health guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-health) and inspect the named guest only when authorised. |
| Performance or events are absent | Inspect the actual associated rules, counter paths, sampling intervals, event selectors, streams and destinations. Check whether the relevant event actually occurred. | No matching events can be normal. Existing Security collection may be owned by another workload; do not remove or duplicate it. |
| A DCR or extension appears missing | Re-read the machine's extensions and associations through ARM and check permissions and subscription scope. Resource Graph can lag. | `NotObserved` does not exclude a guest-installed agent. A proposed installation or association still needs overlap review and approval. |
| CTI data is stale or a short service change is missing | Check the relevant scan and inventory schedules, timestamps, configured items and documented item limits. Keep an authorised test change present through a scan. | Service/file/registry tracking is scheduled, not real-time. A stop and restart between scans may be missed; stale service state is unknown, not healthy. |
| A software removal seems unexpected | Compare inventory with subsequent changes and check the observation time and publisher. | User-level software can be reported as removed when a user signs out; a removal record alone does not establish an uninstall. |
| CTI rule creation or file tracking is uncertain | Compare the current [CTI support matrix](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/change-tracking-inventory-support-matrix) and [DCR example](https://learn.microsoft.com/en-us/azure/automation/change-tracking/change-tracking-data-collection-rule-creation) with the actual configuration. | The published Windows file-setting casing and example frequency need confirmation. Do not guess or associate a second CTI DCR. |
| Alerts do not fire, or would duplicate an existing rule | Inspect existing rule scopes, criteria, evaluation windows, state and Action Group ownership/recipients. Compare the planned query and actual data arrival. | Draft new alerts and Action Groups are disabled. Do not send test notifications, change existing rules or add equivalent ones without approval. |
| A Logs query fails or returns a partial result | Check workspace and table permissions, authentication, query syntax, endpoint and the bounded time range. Use current [Logs API documentation](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/api/overview). | Treat HTTP errors and HTTP-200 partial errors as failures, not zero data. Query access and control-plane Reader access are not necessarily equivalent. |
| The private review generator refuses a report | Check its age, successful discovery checks, selected subscriptions, workspace and server scope, and whether its output path is Git-ignored. | Refresh discovery with read-only permissions. The generated review never certifies deployment readiness. |
| Demo restore reports an uncertain or changed item | Preserve the private journal and inspect the named test item or service using approved read-only checks. Compare its current state with the recorded operation and the [demo recovery guidance](customer-demo-script.md#draft-automation-and-safeguards). | Do not blindly retry a service start or delete a changed file/key. Manual recovery requires owner review and separate approval; an event or ingested record cannot be individually undone. |

## Recording an issue

Record a sanitised symptom, timestamp, affected capability, investigation,
resolution and validation outcome. Keep resource IDs, query results, event
messages, recipients and screenshots containing customer data in approved
private storage. No issue or fix has yet been validated through a PoC
deployment. Additional collection, alerts and troubleshooting queries can
affect cost and data handling; review them before use.
