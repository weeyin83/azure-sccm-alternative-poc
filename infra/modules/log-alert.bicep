@description('Name of a new, PoC-owned scheduled query alert. Check for equivalent existing alerts first.')
param name string

@description('Alert display name.')
param displayName string

@description('Azure region for the log search alert. Verify regional support for the selected workspace.')
param location string

@description('Description including purpose and tuning rationale.')
param alertDescription string

@description('Existing Log Analytics workspace resource ID.')
param workspaceResourceId string

@description('Action Group resource ID. Prefer an approved existing group.')
param actionGroupResourceId string

@description('KQL returning at least one row when the condition is met.')
param query string

@description('Evaluation period, for example PT5M.')
@allowed([
  'PT5M'
  'PT10M'
  'PT15M'
])
param evaluationFrequency string = 'PT5M'

@description('Lookback window, for example PT15M.')
@allowed([
  'PT10M'
  'PT15M'
  'PT30M'
  'PT1H'
  'PT2H'
])
param windowSize string = 'PT15M'

@description('Explicit query history. It must cover the longest lookback in the query and be at least the alert window.')
@allowed([
  'PT10M'
  'PT15M'
  'PT30M'
  'PT1H'
  'PT2H'
  'P1D'
  'P2D'
])
param queryTimeRange string

@description('Choose automatic resolution explicitly. For stateful alerts, missing or stale data must not masquerade as recovery.')
param autoMitigate bool

@description('Split on the query output ResourceId column. This creates a separate, billable series for each value.')
param splitByResourceId bool

@description('Azure Monitor alert severity: 0 (critical) through 4 (verbose).')
@minValue(0)
@maxValue(4)
param severity int = 2

@description('Enable only after duplicate checks, test-server validation and notification approval.')
param enabled bool = false

@description('Tags for the alert rule.')
param tags object = {}

resource alert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: name
  location: location
  kind: 'LogAlert'
  tags: tags
  properties: {
    displayName: displayName
    description: alertDescription
    enabled: enabled
    severity: severity
    evaluationFrequency: evaluationFrequency
    windowSize: windowSize
    overrideQueryTimeRange: queryTimeRange
    scopes: [
      workspaceResourceId
    ]
    criteria: {
      allOf: [
        {
          query: query
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: splitByResourceId ? [
            {
              name: 'ResourceId'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ] : []
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupResourceId
      ]
    }
    autoMitigate: autoMitigate
  }
}

output resourceId string = alert.id
