# Query library: Build in progress

The `.resource-graph.kql` files run with Azure Resource Graph, which reports
Azure resource inventory and configuration. It does not provide SCCM-style
guest hardware inventory. Other files run in the nominated Log Analytics
workspace and report guest data.

Log Analytics queries use an empty `ServerIds` list until approved Arc resource
IDs are supplied for a session; an empty list returns no results. Do not commit
customer IDs. The heartbeat query starts from a configured expected-server
datatable so a never-reporting server can be represented. Keep deliberately
powered-off machines out of that expected-online set. The service query only
checks service names explicitly placed in its `ExpectedServices` list.

These are draft queries and have not been executed against live records. In
particular, review the actual CTI `ConfigDataType`, service inventory freshness,
resource IDs and counter names after deployment approval. CTI collection is
scheduled: absence of a change is not proof that it did not occur. A latest
inventory record is not a real-time state guarantee. The software reconciliation
window is 30 days; extend only after checking workspace history and cost.

Still required: syntax-check Resource Graph and Log Analytics queries without
customer data, test fixtures for service transitions and never-reporting hosts,
and query checks against real workspace data after deployment approval.

Sources checked with Microsoft Learn MCP:
[Resource Graph Arc samples](https://learn.microsoft.com/en-us/azure/azure-arc/servers/resource-graph-samples),
[Perf](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/perf),
[Event](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/event),
[ConfigurationData](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/configurationdata),
[ConfigurationChange](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/configurationchange),
[Heartbeat](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/heartbeat),
[CTI support matrix](https://learn.microsoft.com/en-us/azure/azure-change-tracking-inventory/change-tracking-inventory-support-matrix).
