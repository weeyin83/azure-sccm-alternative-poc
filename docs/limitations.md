# Limitations and natural next steps

- This PoC replaces selected inventory, monitoring, change tracking and alerting
  capabilities, not Configuration Manager as a whole.
- Azure Resource Graph provides Azure resource inventory, not SCCM-style guest
  hardware inventory. Guest software and configuration evidence requires the
  current AMA-based Change Tracking and Inventory service.
- Change collection is scheduled, not real-time. See the documented frequencies,
  limits and ingestion-delay caveats in [architecture](architecture.md).
- Discovery is control-plane only; extension provisioning, DCR configuration or
  a workspace solution does not prove working guest collection.
- No new telemetry, resources or paid services are enabled during Discovery.
  Later collection can add ingestion, retention, alerting and service charges;
  verify costs, licensing benefits, permissions and data handling before approval.
- Workbooks are a **stretch goal**, deferred until the core design is approved.
- Exclude all deprecated monitoring components. VM Insights Map and Dependency
  Agent are deprecated and retire on 30 June 2028; see the verified lifecycle
  sources in [architecture](architecture.md). Their absence does not prevent
  AMA-based performance/event monitoring or current Change Tracking.
- CTI collects all Windows services rather than a collection-time allowlist.
  Current published Windows software/service limits are 250 items each; verify
  required items are represented before claiming complete estate coverage.
- The US$200/month target is not a hard Azure spending cap. Usage and applicable
  licensing must be measured, and attributable existing services and host costs
  included before deployment. Budgets notify; they do not stop consumption.

## Out of scope: natural next steps

Do not build these as part of this PoC:

- Patching with Azure Update Manager.
- Application deployment.
- Operating system deployment.
- Machine Configuration.

Each requires separate discovery, design, cost/licensing assessment and approval.
