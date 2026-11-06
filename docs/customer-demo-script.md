# Customer demonstration script

**Draft only: do not run the demonstration yet.** The Build, complete
preflight and deployment validation are outstanding. No test server, guest
changes or notifications have been approved. Workbooks are optional stretch
scope; the core demonstration uses the Azure portal, Resource Graph and the
scoped [query library](../queries/).

## Preparation

- Obtain explicit deployment and guest-change approval for one named test
  server, an existing disposable test service, synthetic registry/file items,
  any test event or CPU load, and any test notifications. Do not use
  production configuration. The owner has **deferred test-application
  installation and removal**; no application is installed by the draft script.
- Refresh discovery and review the private cutover manifest, existing
  collections and alerts. Reuse the nominated workspace and preserve shared
  resources. Populate query server/service lists privately; never commit IDs.
- Confirm the baseline and collection settings, expected-online period,
  workspace permissions, ingestion, cost and data-handling arrangements.
  Complete [validation](validation.md) before presenting.
- The [draft demo automation](../scripts/demonstration/Invoke-DemoChanges.ps1)
  has passed simulated-host tests only. Windows integration, including the
  private ACLs and native file, registry, service and event operations, has not
  been tested. Do not run it or change a guest until that testing, the
  prerequisites below and separate guest-change approval are complete.

## Draft automation and safeguards

The script runs **locally on one explicitly named Windows Server**, not
remotely. It requires 64-bit PowerShell 7.4+, Git, a local copy of this
repository and an elevated administrator session. It refuses clients and
domain controllers, wildcard names and a computer name that does not match
the local NetBIOS name. It makes no Azure calls.

Before any later, separately approved use:

- Nominate an **existing disposable service** that is already running,
  restartable, safe to stop for the entire observation period and not used by
  a production workload. The script refuses disabled or non-stoppable
  services, active dependents and stopped dependencies; it compares the
  service path, account, start mode and relationship lists before control.
  It does not change the service start type. Owner review is still required:
  the script cannot prove a service is disposable or that it has no side effects.
- Select a pre-existing, dedicated directory named `ArcSccmPoc-<name>` on a
  fixed local NTFS drive, outside this repository, Windows and Program Files. It
  and its ancestors must not be links. Choose an absent file in that directory
  named `ArcSccmPoc-<name>.txt`. Confirm CTI can read it and that its exact
  path is in the reviewed collection configuration. Creating a directory on
  the guest is itself a guest change requiring approval. ReFS is not supported
  by this draft: its 128-bit file identities are not checked by the script.
- Select an absent direct child `HKLM:\SOFTWARE\ArcSccmPoc-<name>` in the
  64-bit registry view. The script creates only the synthetic `DemoState`
  string value. Configure the matching CTI item using the corresponding
  `HKEY_LOCAL_MACHINE\SOFTWARE\...` key and `DemoState` value; verify the
  actual CTI DCR schema and settings first.
- Choose synthetic, non-secret items and coordinate exclusive use of the test
  directory, registry key and service. Snapshot checks cannot prevent every
  race with another administrator or process, particularly between checking a
  registry key and deleting it. If concurrent changes cannot be excluded,
  do not run the script.
- If an event is approved, nominate an **already registered Application**
  event source and event ID covered by the reviewed DCR. No event source is
  registered. A warning event is append-only and cannot be individually
  reversed; never clear a shared log. The source's message resources may not
  render an arbitrary test ID as a friendly description.
- A CPU load is optional, off by default and limited to 15 seconds on one
  PowerShell thread. It can saturate one logical CPU and can affect workloads;
  obtain separate approval. A short load can be missed by the actual sampling
  interval, including the observed 600-second collection.

### Later use after approval and Windows validation

The following illustrates the stages; it is **not permission to run them**.
Populate the variables privately and keep the resulting state path private.
Use `-WhatIf` first for each stage. It performs local preflight reads but no
demo writes; it does not prove Azure collection or authorise guest changes.

```powershell
# Values are selected and approved locally; do not commit them.
$prepare = @{
    TestComputerName = $approvedNetbiosName
    AcknowledgeTestOnly = $true
    TestServiceName = $approvedDisposableServiceName
    TestFilePath = $approvedSyntheticFilePath
    TestRegistryKey = $approvedSyntheticRegistryKey
}
./scripts/demonstration/Invoke-DemoChanges.ps1 @prepare -WhatIf
# Only after the separate approval and Windows validation:
$prepared = ./scripts/demonstration/Invoke-DemoChanges.ps1 @prepare -Confirm
$privateStatePath = $prepared.StatePath
```

Preparation creates the absent file and registry key with synthetic baseline
values. It does **not** stop the service. Wait for, and verify, the actual
baseline in CTI before proceeding. The `-BaselineObserved` switch is the
operator's assertion, not an automated proof. The documented scan periods
and ingestion delay apply.

```powershell
$change = @{
    TestComputerName = $approvedNetbiosName
    AcknowledgeTestOnly = $true
    StatePath = $privateStatePath
    Change = $true
    BaselineObserved = $true
}
./scripts/demonstration/Invoke-DemoChanges.ps1 @change -WhatIf
# Only after the separate approval and observed baseline:
./scripts/demonstration/Invoke-DemoChanges.ps1 @change -Confirm
```

The change stage modifies the synthetic file and registry value, then stops the
designated service until revert. If separately approved, add
`-WriteTestEvent -EventSource $approvedExistingSource -EventId $approvedEventId`
and/or `-CpuSeconds $approvedSeconds`; neither is enabled by default. Keep the
changed state present until it is observed, then restore promptly:

```powershell
$restore = @{
    TestComputerName = $approvedNetbiosName
    AcknowledgeTestOnly = $true
    StatePath = $privateStatePath
    Revert = $true
}
./scripts/demonstration/Invoke-DemoChanges.ps1 @restore -WhatIf
# Only after the separate approval:
./scripts/demonstration/Invoke-DemoChanges.ps1 @restore -Confirm
```

The journal is written under the Git-ignored `scripts/discovery/output/`
directory, with owner-only protection and an exclusive per-run lock. It
contains the host, service and test paths: treat it as private, never
force-add it to Git, and retain it until recovery has been verified. Windows
ACL handling is **not yet validated**. The script records intent before each
operation, checks file identity, content and metadata, and checks registry
contents and ACLs before changes or removal. It never overwrites an existing
test item.

If a change or restore fails, preserve the journal and follow the reported
error. An uncertain file/key creation or modified item is not automatically
removed; an uncertain stopped service or restart is not blindly started.
Other independently safe cleanup may still proceed. An owner must inspect and
separately approve any manual recovery; retry `-Revert` only after resolving
the reported ambiguity. A completed revert is idempotent and leaves the
private journal for review. The event, any already ingested data and any
notifications cannot be undone. Changes and queries can incur ingestion,
retention, query and alert charges; the US$200/month target remains provisional.

## Nine scenarios

Times below are collection intervals or query/evaluation expectations, **not
end-to-end guarantees**. Ingestion and alert evaluation add delay. The actual
configuration must be validated on the approved host.

| Scenario | What to show and what the administrator sees | Configuration Manager capability replaced | Azure services | Operational benefit | Expected timing |
| --- | --- | --- | --- | --- | --- |
| 1. Central view of all servers | Show [server estate](../queries/server-estate.resource-graph.kql) and [monitoring coverage](../queries/monitoring-coverage.resource-graph.kql): Arc status, OS and observed extension/DCR coverage. | Device collection and estate overview. | Arc and Resource Graph. | One Azure control-plane view across the selected estate. It is not complete guest hardware inventory. | Arc reporting and Resource Graph are eventually consistent; no fixed immediate-update guarantee. |
| 2. CPU, memory and disk monitoring | Show [performance](../queries/performance.kql): CPU, available memory, commit percentage and disk capacity/activity for selected hosts and volumes. | Server performance monitoring. | AMA, DCR and Log Analytics. | Compare trends and investigate capacity without a Configuration Manager client. Commit percentage is not physical RAM utilisation. | The proposed DCR samples at 60 seconds; the existing rule observed in discovery samples most counters at 600 seconds. Allow ingestion delay. |
| 3. Windows event monitoring | Show scoped critical/error records in [windows-events.kql](../queries/windows-events.kql), including source and event ID. A designated test event requires separate guest approval. | Central event investigation. | AMA, event DCR and Log Analytics. | Investigate selected System and Application events centrally. | Event collection and ingestion are asynchronous. A quiet log does not prove a collection fault. |
| 4. Installed software inventory | Show [software-current.kql](../queries/software-current.kql): last inventory reconciled with subsequent observed changes, including stale or ambiguous evidence. | Hardware/software inventory, limited here to software. | AMA-based Change Tracking and Inventory, Log Analytics. | Find observed software and publisher across selected servers. | Inventory is scheduled separately; the draft DCR requests a 10-hour inventory cycle, which must be validated. Software changes are scanned every 30 minutes, plus ingestion delay. |
| 5. Software installs and removals | **Deferred:** the draft automation does not install or remove an application. If suitable approved historical evidence exists, show the [installations](../queries/software-installations.kql) and [removals](../queries/software-removals.kql) queries without claiming a new test change; otherwise mark this scenario unvalidated. | Software inventory change history. | AMA-based Change Tracking and Inventory, Log Analytics. | Investigate observed additions and removals centrally. | Windows software changes are scanned every 30 minutes, plus ingestion delay. User-level application sign-out can produce an apparent removal; investigate before claiming an uninstall. |
| 6. Registry and file changes | Show [registry](../queries/registry-changes.kql) and [file](../queries/file-changes.kql) changes for explicitly approved synthetic items; do not expose value contents. | Selected configuration change tracking. | AMA-based Change Tracking and Inventory, Log Analytics. | Review changes to nominated configuration items. | Registry: 50 minutes; Windows files: 30–40 minutes, plus ingestion. The draft file settings still need validation. |
| 7. Windows service status and configuration | Show [service changes](../queries/service-changes.kql) and [expected-running services](../queries/services-expected-running.kql), including unknown or stale states. Only use the designated disposable service. | Service inventory and configuration monitoring. | AMA-based Change Tracking and Inventory, Log Analytics. | Identify observed state/start-type changes and services requiring investigation. | Windows services are scanned every 10–30 minutes, plus ingestion. A stop and restart between scans can be missed; a stale observation is not live state. |
| 8. Querying data with KQL | Open one scoped guest query and the Resource Graph inventory query. Explain their source tables, time range and output; distinguish Azure resource data from guest data. | Custom reporting and investigation. | Resource Graph, Log Analytics and KQL. | Reusable, explainable investigations without changing collection. | Queries can return only data already ingested or indexed. Rendering time varies; they can incur query charges. |
| 9. Alerting on unexpected events | After separately approved configuration and notification testing, show a non-duplicate alert, its condition, current state and Action Group. | Operational alerting. | Azure Monitor alerts, Log Analytics and Action Groups. | Operators receive a reviewed notification without manually watching a query. | Planned evaluations are every 5–15 minutes after the signal reaches the workspace; CTI scan and ingestion delays come first. Alert definitions and live testing are not yet complete. |

## Close and restore

Explain the scheduled nature of CTI, inventory limits, missing/unknown states,
privacy considerations and provisional cost target. If and only if a later
approved test has run, use its validated rollback procedure to restore the
registry/file items and service state. The application scenario remains
deferred. A written Windows event
is an append-only audit record and cannot be individually reversed by this
PoC; do not clear a shared event log. Verify the approved rollback and preserve
the shared workspace, unrelated collections and existing alerts.

Implementation references: [CTI DCR settings](https://learn.microsoft.com/en-us/azure/automation/change-tracking/change-tracking-data-collection-rule-creation),
[registry key creation](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regcreatekeyexw),
[file identity](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle),
[file deletion by handle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle)
and [Windows event sources](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-registereventsourcew).
