@description('Name of a new, PoC-owned Action Group. Reuse an approved existing group when suitable.')
param name string

@description('Short display name shown in notifications. Maximum 12 characters.')
@maxLength(12)
param groupShortName string

@description('Action Group region. Use global for this resource type.')
param location string = 'global'

@description('Email receivers approved for PoC alert notifications. Do not store customer addresses in tracked parameter files.')
@minLength(1)
param emailReceivers array

@description('Whether notifications are enabled. Keep false until recipients and alert behaviour are approved.')
param enabled bool = false

@description('Tags for the Action Group.')
param tags object = {}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    groupShortName: groupShortName
    enabled: enabled
    emailReceivers: [
      for (receiver, index) in emailReceivers: {
        name: 'email-${index}'
        emailAddress: receiver.emailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

output resourceId string = actionGroup.id
