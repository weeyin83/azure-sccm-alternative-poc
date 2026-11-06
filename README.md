# Azure Arc Configuration Manager replacement PoC

Demonstrate selected Windows Server management capabilities using Azure Arc and
native Azure services. **Current phase: Build, in progress.** No infrastructure has been
deployed. Workbooks are stretch scope, not a core prerequisite.

Read-only discovery completed across the approved scope and was refreshed on
6 November 2026. All 3 Windows Arc resources now report **Connected**; this is
control-plane status, not proof of healthy guest collection. Two have
successfully provisioned AMA and Change Tracking extensions with existing DCR
associations. The third still has neither observed. See the
[sanitised findings](docs/discovery-findings.md). The [approved architecture](docs/architecture.md)
reuses the nominated Arc workspace, excludes deprecated monitoring components,
and targets US$200/month subject to measured usage and attributable existing
costs. Deployment, cleanup and guest changes still require explicit approval;
none have run.

The Build is **not complete or deployable**. The draft staged entry point is
[infra/main.bicep](infra/main.bicep) and independent modules are in
[infra/modules/](infra/modules/). Neither detects existing resources or
equivalent collection. Reuse-first preflight and deployment tooling, alert
ownership and integration, Windows testing of the draft demonstration tooling
and live end-to-end validation remain outstanding. Application installation
and removal in the demo are deferred. A [private alert parameter generator](docs/deployment.md#prepare-review-only-alert-parameters)
is available for drafting, but does not approve any deployment. The [query library](queries/) has passed
empty-scope and selected synthetic checks, but has not been validated against
actual guest data. See the [proposed cutover and Build sources](docs/deployment.md).
Do not deploy the draft entry point or individual modules.

Draft [validation](docs/validation.md),
[troubleshooting](docs/troubleshooting.md) and
[customer demonstration](docs/customer-demo-script.md) guides describe the
remaining gates; they do not authorise deployment or guest changes.

## Run read-only discovery

Use PowerShell 7.4+ and Azure CLI with the `resource-graph` CLI extension and Git
already installed. Authenticate to the intended Azure cloud before running. The script
does not install dependencies, sign in, change the selected subscription,
register providers or trigger policy remediation. It uses Azure CLI and
Resource Graph from PowerShell; Az PowerShell modules are not required.

Use Reader access across the requested subscriptions and any referenced shared
monitoring resources, plus visibility of inherited management-group policy
definitions. Reader access at a single resource is not complete subscription
visibility. Do not grant Contributor merely to perform discovery.

```powershell
# Supply approved subscription GUIDs from your environment.
$subscriptionIds = @(
    (Read-Host 'Subscription ID')
)
./scripts/discovery/Invoke-ArcDiscovery.ps1 -SubscriptionId $subscriptionIds
```

Each run creates a unique directory under `scripts/discovery/output/` containing:

- `report.json`: scope, timestamp, success/failure of each read, server
  extensions and associations, full monitoring resource definitions, workspace
  evidence, policy assignments and expanded initiative definitions.
- `servers.csv`: one row per observed Windows Arc server, with coverage states.
- `findings.md`: private counts, caveats and review recommendations.

The collector verifies the output is ignored by Git and creates an owner-only
evidence root and run directory. On Linux and macOS these must be owned by the
current user, with directory mode `700` and report-file mode `600`. An existing
insecure output directory is rejected rather than silently changing its access.
On Windows the directory ACL is restricted to the current user; this path still
needs testing on Windows. Do not copy reports to a less protected location.
**Do not force-add the output to Git.** Reports can
contain confidential infrastructure metadata, queries, receiver addresses and
webhook URLs. Store them securely; even CSVs should be treated as untrusted
customer data and opened with spreadsheet formula evaluation disabled.

Any failed read writes an **Incomplete** report and raises a terminating error.
Successful collection is **CollectedPendingReview**, not validated monitoring.
`Provisioned` means only that an extension reports successful provisioning.
`NotObserved` means a successful read did not return that extension; it does not
rule out a guest-installed agent. `Unknown` indicates a failed read.
Resource Graph is eventually consistent and RBAC-filtered.

The collector enumerates the supplied subscriptions, follows DCR and workspace
references and alert Action Group references, and records inaccessible resources
as failures. Include subscriptions containing shared workspaces, alerts and
solutions to enumerate their surrounding configuration. All alert rules are
retained for review: log queries and activity-log conditions can refer to an
estate indirectly, so an unresolved relationship is **not** permission to add
a duplicate alert. Policy candidates are text-based evidence, not effective
compliance or exemption evaluation.

Keep [discovery findings](docs/discovery-findings.md) sanitised when rerunning
discovery. Review the [architecture and cost model](docs/architecture.md);
explicit deployment approval is still required before Azure changes, including
any cleanup of existing security roles or collections.

## Check telemetry without changing resources

[Get-ArcTelemetrySummary.ps1](scripts/discovery/Get-ArcTelemetrySummary.ps1)
uses the [Logs Query API](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/api/request-format)
to return counts and latest timestamps for selected servers, without returning
guest records or resource IDs. Populate these variables locally from the
private discovery report; do not paste customer IDs into shared logs or chat:

```powershell
./scripts/discovery/Get-ArcTelemetrySummary.ps1 `
    -ReportPath $privateReportPath `
    -WorkspaceResourceId $approvedWorkspaceResourceId `
    -ServerResourceId $approvedArcServerResourceIds
```

The report must be complete and no more than 24 hours old. The default query
window is 24 hours, with an allowed range of 1–48 hours. The current helper
supports Azure public cloud and requires Logs Query access to each table; it
fails if a query or the response is incomplete. The API receives the selected
resource IDs in the query, so apply normal customer data-handling controls.
Queries can incur charges. Counts indicate data observed within the window,
not continuous collection, agent health or alert readiness. In particular,
the absence of matching events alone is not a fault.

## Prepare a private cutover review

[New-ArcCutoverReview.ps1](scripts/discovery/New-ArcCutoverReview.ps1) requires
PowerShell 7.4 or later. It reads a
complete report no more than one hour old and inventories the selected servers,
existing DCRs, associations, alerts, Action Groups and policy assignments.
Reports, optional baseline reports and optional parameter files must be
single-link, owner-only, ignored and untracked files in dedicated subdirectories
of `scripts/discovery/output/`. See the
[private input requirements](docs/deployment.md#itemised-cleanup-and-cutover-proposal).
Use the same locally populated private variables as for the telemetry check:

```powershell
./scripts/discovery/New-ArcCutoverReview.ps1 `
    -ReportPath $privateReportPath `
    -WorkspaceResourceId $approvedWorkspaceResourceId `
    -ServerResourceId $approvedArcServerResourceIds
```

The script makes no Azure calls. It writes a new file beneath the Git-ignored
`scripts/discovery/output/`, checks that the file is ignored and restricts
access to its new directory. The manifest contains resource IDs, DCR settings
and alert criteria; handle it as confidential customer data. It omits Action
Group receiver destinations, which remain in the private source report.
Existing resources and associations are marked for preservation, not removal.

An optional `-ParametersPath $privateArmParametersJson` also compares a
literal ARM JSON parameter file for one draft Bicep stage with the snapshot.
It rejects files over 2 MiB, case-insensitive duplicate JSON fields, missing
or unrecognised operation fields, invalid intervals and
empty required selector or receiver lists. It flags issues such as existing
extension or resource names, possible DCR overlap, existing associations,
unresolved alert intent, and an Action Group that needs review. For planned
associations it compares literal performance and event selectors, streams and
workspace destinations against existing and
other planned associations, then compares recorded sampling, inline transforms
and output streams when possible. Unknown or named transformations and
unmatched destinations remain review findings; no literal match does not prove
there is no semantic overlap. It also flags simple empty literal data lists and literal
`ago()` lookbacks longer than an alert's configured query range. These checks
are not a KQL parser and cannot establish valid scope or complete history.
It does not copy proposed receiver destinations or query text into the
assessment. References to external parameter values are rejected because
they cannot be inspected.

After a new read-only discovery, `-BaselineReportPath $reviewedReportPath`
compares it with an earlier complete report:

```powershell
./scripts/discovery/New-ArcCutoverReview.ps1 `
    -ReportPath $freshReportPath `
    -BaselineReportPath $reviewedReportPath `
    -WorkspaceResourceId $approvedWorkspaceResourceId `
    -ServerResourceId $approvedArcServerResourceIds
```

Both reports must cover the same subscriptions and selected resources, with
complete checks, resource details, workspace links and policy definitions.
The current collection must have **started** within the past 15 minutes;
reports created before collection-start timestamps were added can serve only
as the baseline. The private manifest identifies added, removed and modified
captured servers, resources, workspaces, policy assignments and definitions,
without copying Action Group destinations. It compares all captured DCR,
alert and receiver properties, including selector, stream, transform and
destination changes. Object-key order and each server's extension and
association list order are normalised. Other array reordering can produce a
conservative drift finding.

This is a snapshot comparison, not a fresh Azure read: repeat discovery and
review the differences immediately before any proposed what-if. It cannot
prove complete Azure visibility or Resource Graph freshness. Guest-installed
agents, all AMA public settings, effective policy exemptions and remediation
are not fully captured. `NoDriftObserved` is not proof of equivalent
collection, alert safety or authorisation.

The comparison is deliberately conservative and incomplete: it does not
prove semantic equivalence, check live Azure state or guest health, or
approve a cutover. Whether or not a parameter file is supplied, the output is
**review-only**, not a safe preflight and not permission to run what-if or
deploy. No actual deployment parameters have yet been approved.

## Local validation

```powershell
./tests/discovery/Invoke-ArcDiscovery.Tests.ps1
./tests/discovery/Get-ArcTelemetrySummary.Tests.ps1
./tests/discovery/New-ArcCutoverReview.Tests.ps1
./tests/deployment/New-ArcAlertParameters.Tests.ps1
./tests/demonstration/Invoke-DemoChanges.Tests.ps1
Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Severity Warning,Error
Invoke-ScriptAnalyzer -Path ./tests -Recurse -Severity Warning,Error
```

The PowerShell tests use synthetic data, mock Azure CLI where applicable and
must not contact Azure. Demo tests simulate the guest and exercise private
journal handling locally; they do not execute the Windows guest operations.
The Bicep
module contract tests are also local:

```bash
python3 -m unittest discover -s tests/infra -v
```

Python 3 must be available to run the test suites. In the current container,
`python3` is not on `PATH`; the Azure CLI installation provides
`/opt/az/bin/python3`. That interpreter path is installation-specific.

Check the draft entry point and modules with `az bicep build --file <file>
--stdout` and `az bicep lint --file <file>`. Target-scope what-if is pending
safe preflight and reviewed private parameters; it has not been run.

Optional read-only query checks use the nominated workspace and the private
workspace evidence JSON alongside its discovery `report.json`. They execute
synthetic fixtures and empty-scope queries, and Resource Graph queries that
return zero rows. No customer records are returned; access to all recorded
subscriptions and the workspace is required. Queries can incur service charges.
Keep the evidence path and data private.

```bash
export POC_WORKSPACE_EVIDENCE=/private/path/to/design-workspace.json
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/queries -v
```

## Git push from the dev container

The dev container installs Git LFS, which is required by the existing pre-push
hook. Rebuild the container after pulling changes to its build configuration.
GitHub authentication is separate: if a push reports that it cannot obtain a
password, sign in interactively from the container and configure Git to use
the GitHub CLI credentials:

```bash
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git --hostname github.com
gh auth status --hostname github.com
git push
```

Follow the browser/device prompts; do not paste credentials into chat or
commit them. A push sends committed changes only, and the ignored discovery
output must remain private.

## Scope boundaries

See [limitations and natural next steps](docs/limitations.md). See
[standing rules](.github/copilot-instructions.md) for safety and approval gates.
