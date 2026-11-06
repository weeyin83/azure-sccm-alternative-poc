@description('Name of the existing Arc machine in this resource group.')
param machineName string

@description('Name for a new association. Check all existing associations before deploying.')
param associationName string

@description('Resource ID of the approved DCR to associate.')
param dataCollectionRuleId string

resource machine 'Microsoft.HybridCompute/machines@2025-01-13' existing = {
  name: machineName
}

resource association 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  scope: machine
  name: associationName
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
    description: 'PoC collection association'
  }
}

output resourceId string = association.id
