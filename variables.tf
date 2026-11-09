- bash: |
    set -e
    echo "Checking Kubelogin installation..."
    command -v kubelogin
    kubelogin --version
  displayName: 'Verify Kubelogin'



  - bash: |
      set -euo pipefail
      mkdir -p "$HOME/bin"
      curl -fsSLO https://github.com/Azure/kubelogin/releases/download/v0.2.9/kubelogin-linux-amd64.zip
      unzip -ojd "$HOME/bin" kubelogin-linux-amd64.zip bin/linux_amd64/kubelogin
      rm -f kubelogin-linux-amd64.zip
      chmod +x "$HOME/bin/kubelogin"
      echo "##vso[task.prependpath]$HOME/bin"
      "$HOME/bin/kubelogin" --version
    displayName: 'Install Kubelogin'
