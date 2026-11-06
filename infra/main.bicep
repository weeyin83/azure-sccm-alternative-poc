targetScope = 'subscription'

// Draft orchestration only. A reviewed reuse-first preflight is required before deployment.
type Scope = {
  subscriptionId: string
  resourceGroupName: string
}

type ExtensionPlan = {
  scope: Scope
  machineName: string
  extensionName: string
  location: string
  typeHandlerVersion: string
}

type PerformancePlan = {
  scope: Scope
  name: string
  location: string
  counterSpecifiers: array
  samplingFrequencyInSeconds: int
  eventXPathQueries: array
}

type ChangeTrackingPlan = {
  scope: Scope
  name: string
  location: string
  registryInfo: array
  fileInfo: array
  fileCollectionFrequency: int
  serviceCollectionFrequency: int
}

type AssociationPlan = {
  scope: Scope
  machineName: string
  associationName: string
  dataCollectionRuleId: string
}

type ActionGroupPlan = {
  scope: Scope
  name: string
  groupShortName: string
  emailReceivers: array
}

type AlertPlan = {
  scope: Scope
  name: string
  displayName: string
  location: string
  description: string
  actionGroupResourceId: string
  query: string
  evaluationFrequency: 'PT5M' | 'PT10M' | 'PT15M'
  windowSize: 'PT10M' | 'PT15M' | 'PT30M' | 'PT1H' | 'PT2H'
  queryTimeRange: 'PT10M' | 'PT15M' | 'PT30M' | 'PT1H' | 'PT2H' | 'P1D' | 'P2D'
  autoMitigate: bool
  splitByResourceId: bool
  severity: int
}

@description('Only the selected stage is evaluated. Run each stage separately after the previous gate passes.')
@allowed([
  'ama'
  'collection-rules'
  'associations'
  'change-tracking-extension'
  'alerting'
])
param stage string

@description('Resource ID of the owner-approved existing Log Analytics workspace.')
param workspaceResourceId string

@description('Common tags for newly created PoC resources.')
param tags object = {}

@description('Explicitly reviewed AMA extension creations; omit already installed or suitable extensions.')
param amaExtensions ExtensionPlan[] = []

@description('Explicitly reviewed Change Tracking extension creations; omit suitable existing extensions.')
param changeTrackingExtensions ExtensionPlan[] = []

@description('Explicitly reviewed new performance/event DCRs; do not include suitable existing rules.')
param performanceRules PerformancePlan[] = []

@description('Explicitly reviewed dedicated Change Tracking DCRs; the scope must match the workspace resource group.')
param changeTrackingRules ChangeTrackingPlan[] = []

@description('Explicitly reviewed new associations. Do not add a second Change Tracking rule to a machine.')
param associations AssociationPlan[] = []

@description('Explicitly reviewed new Action Groups; omit a suitable existing group.')
param actionGroups ActionGroupPlan[] = []

@description('Explicitly reviewed non-duplicate log alerts. Alerts are created disabled.')
param alerts AlertPlan[] = []

module ama 'modules/ama-extension.bicep' = [for item in amaExtensions: if (stage == 'ama') {
  scope: resourceGroup(item.scope.subscriptionId, item.scope.resourceGroupName)
  params: {
    machineName: item.machineName
    extensionName: item.extensionName
    location: item.location
    typeHandlerVersion: item.typeHandlerVersion
    tags: tags
  }
}]

module changeTracking 'modules/change-tracking-extension.bicep' = [for item in changeTrackingExtensions: if (stage == 'change-tracking-extension') {
  scope: resourceGroup(item.scope.subscriptionId, item.scope.resourceGroupName)
  params: {
    machineName: item.machineName
    extensionName: item.extensionName
    location: item.location
    typeHandlerVersion: item.typeHandlerVersion
    tags: tags
  }
}]

module performance 'modules/performance-events-dcr.bicep' = [for item in performanceRules: if (stage == 'collection-rules') {
  scope: resourceGroup(item.scope.subscriptionId, item.scope.resourceGroupName)
  params: {
    name: item.name
    location: item.location
    workspaceResourceId: workspaceResourceId
    counterSpecifiers: item.counterSpecifiers
    samplingFrequencyInSeconds: item.samplingFrequencyInSeconds
    eventXPathQueries: item.eventXPathQueries
    tags: tags
  }
}]

module trackingRule 'modules/change-tracking-dcr.bicep' = [for item in changeTrackingRules: if (stage == 'collection-rules') {
  scope: resourceGroup(item.scope.subscriptionId, item.scope.resourceGroupName)
  params: {
    name: item.name
    location: item.location
    workspaceResourceId: workspaceResourceId
    registryInfo: item.registryInfo
    fileInfo: item.fileInfo
    fileCollectionFrequency: item.fileCollectionFrequency
    serviceCollectionFrequency: item.serviceCollectionFrequency
    tags: tags
  }
}]

module association 'modules/dcr-association.bicep' = [for item in associations: if (stage == 'associations') {
  scope: resourceGroup(item.scope.subscriptionId, item.scope.resourceGroupName)
  params: {
    machineName: item.machineName
    associationName: item.associationName
    dataCollectionRuleId: item.dataCollectionRuleId
  }
}]

module actionGroup 'modules/action-group.bicep' = [for item in actionGroups: if (stage == 'alerting') {
  scope: resourceGroup(item.scope.subscriptionId, item.scope.resourceGroupName)
  params: {
    name: item.name
    groupShortName: item.groupShortName
    emailReceivers: item.emailReceivers
    enabled: false
    tags: tags
  }
}]

module alert 'modules/log-alert.bicep' = [for item in alerts: if (stage == 'alerting') {
  scope: resourceGroup(item.scope.subscriptionId, item.scope.resourceGroupName)
  dependsOn: [
    actionGroup
  ]
  params: {
    name: item.name
    displayName: item.displayName
    location: item.location
    alertDescription: item.description
    workspaceResourceId: workspaceResourceId
    actionGroupResourceId: item.actionGroupResourceId
    query: item.query
    evaluationFrequency: item.evaluationFrequency
    windowSize: item.windowSize
    queryTimeRange: item.queryTimeRange
    autoMitigate: item.autoMitigate
    splitByResourceId: item.splitByResourceId
    severity: item.severity
    enabled: false
    tags: tags
  }
}]
