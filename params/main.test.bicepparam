using '../main.bicep'

param namePrefix = 'privds02'

param workspaceName = 'synapsews-dev-002'
@secure()
param sqlAdminPassword = 'ChangeMe-Strong!1'  // better: pass via CLI or KeyVault
param initialWorkspaceAdminObjectId = '7180c691-8b70-496f-bb11-e019e5bf64f8'
param filesystemName = 'synfs'
// Optional (empty = skip)
param uami1Name = ''
param uami2Name = ''

/*
param kvRg = 'rg-sc'
param kvName = 'kn-sc'



/*
// Optional SA override (empty = auto)
param storageAccountName = ''
*/
