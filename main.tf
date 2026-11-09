parameters:
  - name: backendServiceConnection
    type: string
  - name: environmentServiceConnection
    type: string
  - name: resourceGroupName
    type: string
    default: false
  - name: storageAccountName
    type: string
    default: false
  - name: containerName
    type: string
    default: false
  - name: stateFileName
    type: string
    default: false
  - name: workingDirectory
    type: string
    default: false
  - name: command
    type: string
    default: false
  - name: aksClusterName
    type: string
    default: false
  - name: aksResourceGroupName
    type: string
    default: false
  - name: environmentVars
    type: object
    default: null
  - name: gitsshknownhosts
    type: string
    default: false
  - name: terraformgitsshpub
    type: string
    default: false

steps:
  - task: InstallSSHKey@0
    displayName: "Install SSH key"
    inputs:
      knownHostsEntry: ${{ parameters.gitsshknownhosts }} #Variable pulled in from Variable Group
      sshPublicKey: ${{ parameters.terraformgitsshpub }} #Variable pulled in from Variable Group
      sshKeySecureFile: "devops"
      addEntryToConfig: true
      configHostAlias: "ssh.dev.azure.com"
      configHostname: "ssh.dev.azure.com"

  - task: TerraformInstaller@1
    displayName: Install Terraform 1.10
    inputs:
      terraformVersion: 1.10.2

  - bash: |
      curl -fsSLO https://github.com/Azure/kubelogin/releases/download/v0.2.9/kubelogin-linux-amd64.zip
      unzip -ojd /usr/local/bin kubelogin-linux-amd64.zip bin/linux_amd64/kubelogin
      rm -f kubelogin-linux-amd64.zip
      kubelogin --version
    displayName: 'Install Kubelogin'

  - task: TerraformTaskV4@4
    displayName: "Terraform: init"
    inputs:
      provider: "azurerm"
      command: "init"
      workingDirectory: ${{ parameters.workingDirectory }}
      backendServiceArm: ${{ parameters.backendServiceConnection }}
      backendAzureRmResourceGroupName: ${{ parameters.resourceGroupName }}
      backendAzureRmStorageAccountName: ${{ parameters.storageAccountName }}
      backendAzureRmContainerName: ${{ parameters.containerName }}
      backendAzureRmKey: ${{ parameters.stateFileName }}
    env: ${{ parameters.environmentVars }}

  - task: AzureCLI@2
    displayName: "Terraform: ${{ parameters.command }}"
    inputs:
      azureSubscription: ${{ parameters.environmentServiceConnection }}
      scriptType: "bash"
      scriptLocation: "inlineScript"
      inlineScript: |
        set -eo pipefail
        az aks get-credentials --resource-group ${{ parameters.aksResourceGroupName }} --name ${{ parameters.aksClusterName }} --overwrite-existing
        if [ $? -eq 0 ]; then
          kubelogin convert-kubeconfig -l azurecli
          cd ${{ parameters.workingDirectory }}
          terraform ${{ parameters.command }}
          rm -f ~/.kube/config
        else
          echo "Kubernetes cluster not found"
        fi
    env: ${{ parameters.environmentVars }}
