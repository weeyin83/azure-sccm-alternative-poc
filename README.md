# Azure Arc Configuration Manager replacement PoC

Demonstrate selected Windows Server management capabilities using Azure Arc and
native Azure services. **Current phase: Design review.** No infrastructure has been
deployed. Workbooks are stretch scope, not a core prerequisite.

Read-only discovery has completed across the approved scope. See the
[sanitised findings](docs/discovery-findings.md): all 3 observed Windows Arc
servers report disconnected because the owner has deliberately powered them off.
Discovery review is recorded. The [proposed architecture](docs/architecture.md)
reuses the nominated Arc workspace, excludes deprecated monitoring components,
and targets US$200/month subject to measured usage and attributable existing
costs. **Awaiting Design approval before Build.** No cleanup or Azure changes
have run.

## Run read-only discovery

Use PowerShell 7.2+ and Azure CLI with the `resource-graph` CLI extension already
installed. Authenticate to the intended Azure cloud before running. The script
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

The output directory is ignored by Git. **Do not force-add it.** Reports can
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
discovery. Review the [architecture and cost model](docs/architecture.md) before
authorising Build; explicit deployment approval is still required before Azure
changes, including any cleanup of existing security roles or collections.

## Local validation

```powershell
./tests/discovery/Invoke-ArcDiscovery.Tests.ps1
Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Severity Warning,Error
Invoke-ScriptAnalyzer -Path ./tests -Recurse -Severity Warning,Error
```

The tests mock Azure CLI and must not contact Azure. Bicep compilation, linting,
what-if and deployments belong to later approved phases; no Bicep files have
been built yet.

## Scope boundaries

See [limitations and natural next steps](docs/limitations.md). See
[standing rules](.github/copilot-instructions.md) for safety and approval gates.
