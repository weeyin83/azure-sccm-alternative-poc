@description('Name of a new, PoC-owned DCR. Verify it does not already exist before deploying.')
param name string

@description('Region of the DCR.')
param location string

@description('Resource ID of the existing, approved Log Analytics workspace.')
param workspaceResourceId string

@description('Windows performance counter specifiers. Validate paths and instances on the test server.')
@minLength(1)
param counterSpecifiers array = [
  '\\Processor(_Total)\\% Processor Time'
  '\\Memory\\Available MBytes'
  '\\Memory\\% Committed Bytes In Use'
  '\\LogicalDisk(*)\\Free Megabytes'
  '\\LogicalDisk(*)\\% Free Space'
  '\\LogicalDisk(*)\\% Idle Time'
  '\\LogicalDisk(*)\\Disk Reads/sec'
  '\\LogicalDisk(*)\\Disk Writes/sec'
  '\\LogicalDisk(*)\\Avg. Disk sec/Read'
  '\\LogicalDisk(*)\\Avg. Disk sec/Write'
]

@description('Performance counter sampling interval in seconds.')
@minValue(1)
param samplingFrequencyInSeconds int = 60

@description('Filtered event log XPath selectors. Security collection is off unless explicitly supplied.')
@minLength(1)
param eventXPathQueries array = [
  'System!*[System[(Level=1 or Level=2 or Level=3)]]'
  'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
]

@description('Tags for the DCR.')
param tags object = {}

resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: name
  location: location
  kind: 'Windows'
  tags: tags
  properties: {
    description: 'Windows performance and filtered event collection'
    dataSources: {
      performanceCounters: [
        {
          name: 'performance'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: samplingFrequencyInSeconds
          counterSpecifiers: counterSpecifiers
        }
      ]
      windowsEventLogs: [
        {
          name: 'windowsEvents'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: eventXPathQueries
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
          'Microsoft-Perf'
          'Microsoft-Event'
        ]
        destinations: [
          'workspace'
        ]
      }
    ]
  }
}

output resourceId string = dcr.id
