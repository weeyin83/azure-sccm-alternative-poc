@description('Name of a new, PoC-owned CTI DCR. Verify it does not already exist before deploying.')
param name string

@description('Region of the existing workspace. Deploy this module to the workspace resource group.')
param location string

@description('Resource ID of the existing, approved Log Analytics workspace.')
param workspaceResourceId string

@description('Approved Windows registry items using the CTI registryInfo schema; HKLM only.')
@minLength(1)
@maxLength(250)
param registryInfo array

@description('Approved Windows file items with synthetic contents; the draft CTI setting shape requires service-side validation.')
@minLength(1)
@maxLength(500)
param fileInfo array

@description('Windows file scan interval in seconds. Supported range is 1800 to 2400.')
@minValue(1800)
@maxValue(2400)
param fileCollectionFrequency int = 1800

@description('Windows service scan interval in seconds. Supported range is 600 to 1800.')
@minValue(600)
@maxValue(1800)
param serviceCollectionFrequency int = 600

@description('Tags for the DCR.')
param tags object = {}

resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: name
  location: location
  tags: tags
  properties: {
    description: 'Dedicated Windows Change Tracking and Inventory collection'
    dataSources: {
      extensions: [
        {
          name: 'CTDataSource-Windows'
          extensionName: 'ChangeTracking-Windows'
          streams: [
            'Microsoft-ConfigurationChange'
            'Microsoft-ConfigurationChangeV2'
            'Microsoft-ConfigurationData'
          ]
          extensionSettings: {
            enableFiles: true
            enableSoftware: true
            enableRegistry: true
            enableServices: true
            enableInventory: true
            registrySettings: {
              registryCollectionFrequency: 3000
              registryInfo: registryInfo
            }
            fileSettings: {
              fileCollectionFrequency: fileCollectionFrequency
              fileInfo: fileInfo
            }
            softwareSettings: {
              softwareCollectionFrequency: 1800
            }
            inventorySettings: {
              inventoryCollectionFrequency: 36000
            }
            servicesSettings: {
              serviceCollectionFrequency: serviceCollectionFrequency
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-ConfigurationChange'
          'Microsoft-ConfigurationChangeV2'
          'Microsoft-ConfigurationData'
        ]
        destinations: [
          'workspace'
        ]
      }
    ]
  }
}

output resourceId string = dcr.id
