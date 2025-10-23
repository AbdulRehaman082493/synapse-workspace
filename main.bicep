targetScope = 'resourceGroup'

/* -------------------- Parameters -------------------- */
@description('Location; defaults to resource group location')
param location string = resourceGroup().location

@description('Short prefix for names (<=10, lowercase/digits)')
@minLength(1)
@maxLength(10)
param namePrefix string = 'syn01'

@description('Synapse workspace name (<=50)')
@minLength(3)
@maxLength(50)
param workspaceName string

@description('SQL admin login for Synapse')
param sqlAdminLogin string = 'synapseadmin'

@secure()
@description('SQL admin password for Synapse')
param sqlAdminPassword string

@description('AAD objectId to make initial Synapse admin')
param initialWorkspaceAdminObjectId string

@description('ADLS Gen2 filesystem (container) name (3–63)')
@minLength(3)
@maxLength(63)
param filesystemName string = 'synfs'

@description('Optional user-assigned identity #1 (existing in this RG). Leave empty to skip')
param uami1Name string = ''

@description('Optional user-assigned identity #2 (existing in this RG). Leave empty to skip')
param uami2Name string = ''

@description('Storage account name (<=24). Leave empty to auto-generate')
@minLength(0)
@maxLength(24)
param storageAccountName string = ''

/* -------------------- Derived -------------------- */
var safePrefix = toLower(replace(namePrefix, '[^a-z0-9]', ''))

// clamp substring length to avoid errors if safePrefix < 12
var vnetNameLen = min(12, length(safePrefix))
var vnetName    = '${substring(safePrefix, 0, vnetNameLen)}-vnet'

// Storage account name (auto if empty)
var saAuto = '${safePrefix}stg${substring(uniqueString(resourceGroup().id), 0, max(0, 24 - length('${safePrefix}stg')))}'
var saName = empty(storageAccountName) ? saAuto : toLower(replace(storageAccountName, '[^a-z0-9]', ''))

// DFS URL for Synapse
var synDfsUrl = 'https://${saName}.dfs.${environment().suffixes.storage}'

/* -------------------- Network -------------------- */
@description('VNet address space')
param vnetAddressPrefix string = '10.60.0.0/22'

@description('PE subnet name')
param peSubnetName string = 'pe-subnet'

@description('PE subnet prefix')
param peSubnetPrefix string = '10.60.0.0/24'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressPrefix ] }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}
var peSubnetId = '${vnet.id}/subnets/${peSubnetName}'

/* -------------------- Private DNS Zones + Links -------------------- */
var blobZone   = 'privatelink.blob.${environment().suffixes.storage}'
var synDevZone = 'privatelink.dev.azuresynapse.net'
var synSqlZone = 'privatelink.sql.azuresynapse.net'


resource pzBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: blobZone
  location: 'global'
}
resource pzSynDev 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: synDevZone
  location: 'global'
}
resource pzSynSql 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: synSqlZone
  location: 'global'
}


resource linkBlob 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: uniqueString('${vnet.id}-blob')
  parent: pzBlob
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource linkSynDev 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: uniqueString('${vnet.id}-syndev')
  parent: pzSynDev
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}
resource linkSynSql 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: uniqueString('${vnet.id}-synsql')
  parent: pzSynSql
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}


/* -------------------- Storage (ADLS Gen2) -------------------- */
resource stg 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: saName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    isHnsEnabled: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  name: 'default'
  parent: stg
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: filesystemName
  parent: blobSvc
  properties: { publicAccess: 'None' }
}

/* Storage Private Endpoint (blob + dfs) */
resource peStg 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${saName}-pe'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${saName}-pls'
        properties: {
          privateLinkServiceId: stg.id
          groupIds: [ 'blob', 'dfs' ]
        }
      }
    ]
  }
}

resource stgZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  name: 'default'
  parent: peStg
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: pzBlob.id } }
    ]
  }
}

/* -------------------- Optional UAMIs (existing) -------------------- */
resource uami1 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (!empty(uami1Name)) {
  name: uami1Name
  scope: resourceGroup()
}
resource uami2 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (!empty(uami2Name)) {
  name: uami2Name
  scope: resourceGroup()
}
var uaiMap = union(
  empty(uami1Name) ? {} : { '${uami1.id}': {} },
  empty(uami2Name) ? {} : { '${uami2.id}': {} }
)

/* -------------------- Synapse Workspace -------------------- */
resource ws 'Microsoft.Synapse/workspaces@2021-06-01' = {
  name: workspaceName
  location: location
  identity: (!empty(uami1Name) || !empty(uami2Name))
    ? { type: 'SystemAssigned,UserAssigned', userAssignedIdentities: uaiMap }
    : { type: 'SystemAssigned' }
  properties: {
    defaultDataLakeStorage: { accountUrl: synDfsUrl, filesystem: filesystemName }
    sqlAdministratorLogin: sqlAdminLogin
    sqlAdministratorLoginPassword: sqlAdminPassword
    publicNetworkAccess: 'Disabled'
    cspWorkspaceAdminProperties: { initialWorkspaceAdminObjectId: initialWorkspaceAdminObjectId }
    managedVirtualNetwork: 'default'
  }
}


/* Synapse Private Endpoints (dev / Sql / SqlOnDemand) */
resource peSynDev 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${toLower(workspaceName)}-dev-pe'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      { name: '${toLower(workspaceName)}-dev-pls', properties: { privateLinkServiceId: ws.id, groupIds: [ 'dev' ] } }
    ]
  }
}
resource peSynSql 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${toLower(workspaceName)}-sql-pe'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      { name: '${toLower(workspaceName)}-sql-pls', properties: { privateLinkServiceId: ws.id, groupIds: [ 'Sql' ] } }
    ]
  }
}
resource peSynSvr 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${toLower(workspaceName)}-sqlo-pe'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      { name: '${toLower(workspaceName)}-sqlo-pls', properties: { privateLinkServiceId: ws.id, groupIds: [ 'SqlOnDemand' ] } }
    ]
  }
}

/* Zone groups for Synapse PEs */
resource synDevZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  name: 'default'
  parent: peSynDev
  properties: { privateDnsZoneConfigs: [ { name: 'syndev', properties: { privateDnsZoneId: pzSynDev.id } } ] }
}
resource synSqlZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  name: 'default'
  parent: peSynSql
  properties: { privateDnsZoneConfigs: [ { name: 'synsql', properties: { privateDnsZoneId: pzSynSql.id } } ] }
}
resource synSvrZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  name: 'default'
  parent: peSynSvr
  properties: { privateDnsZoneConfigs: [ { name: 'synsql2', properties: { privateDnsZoneId: pzSynSql.id } } ] }
}



/* -------------------- Outputs -------------------- */
output storageAccountName string = saName
output dataLakeUrl string = synDfsUrl
output workspaceName string = ws.name
output vnetId string = vnet.id
output peSubnetId string = peSubnetId

