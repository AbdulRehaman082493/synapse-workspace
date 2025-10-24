using '../main.bicep'

param namePrefix = 'privds02'
param workspaceName = 'synapsews-dev-002'
@secure()
param sqlAdminPassword = ''    // leave empty; pass from GH secret
param initialWorkspaceAdminObjectId = '7180c691-8b70-496f-bb11-e019e5bf64f8'
param filesystemName = 'synfs'
param uami1Name = ''
param uami2Name = ''
param storageAccountName = ''  // optional; empty = auto
