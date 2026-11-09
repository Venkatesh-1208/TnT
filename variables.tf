- bash: |
    set -e
    echo "Checking Kubelogin installation..."
    command -v kubelogin
    kubelogin --version
  displayName: 'Verify Kubelogin'
