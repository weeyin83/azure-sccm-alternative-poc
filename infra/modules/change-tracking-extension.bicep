@description('Name of the existing Arc machine in this resource group.')
param machineName string

@description('Name for a new CTI extension. Do not deploy if a suitable CTI extension already exists.')
param extensionName string

@description('Arc machine region.')
param location string

@description('Supported, region-available CTI handler version verified at deployment time.')
param typeHandlerVersion string

@description('Tags for the extension.')
param tags object = {}

resource machine 'Microsoft.HybridCompute/machines@2025-01-13' existing = {
  name: machineName
}

resource extension 'Microsoft.HybridCompute/machines/extensions@2025-01-13' = {
  parent: machine
  name: extensionName
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.ChangeTrackingAndInventory'
    type: 'ChangeTracking-Windows'
    typeHandlerVersion: typeHandlerVersion
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

output resourceId string = extension.id
