#!/usr/bin/env bash
set -euo pipefail
trap 'printf "Tool check failed at line %s.\n" "$LINENO" >&2' ERR

export CHECKPOINT_DISABLE=1
export AZURE_CORE_CHECK_VERSION=false
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no
export AZURE_BICEP_USE_BINARY_FROM_PATH=true

for tool in git terraform az bicep gh; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        printf 'Missing tool: %s. Run the online WSL installer or rebuild the Codespace.\n' "$tool" >&2
        exit 1
    fi
done

git --version
terraform version
az version --output json
bicep --version
gh --version

temp_dir="$(mktemp -d)"
cleanup() {
    rm -f -- "$temp_dir/main.tf" "$temp_dir/main.bicep" "$temp_dir/main.json"
    rmdir -- "$temp_dir"
}
trap cleanup EXIT

printf 'output "starter" {\n  value = "ready"\n}\n' > "$temp_dir/main.tf"
terraform fmt -check "$temp_dir/main.tf"
printf 'param greeting string = '\''ready'\''\noutput message string = greeting\n' > "$temp_dir/main.bicep"
bicep build "$temp_dir/main.bicep" --outfile "$temp_dir/main.json"
az bicep version

printf '\nLocal CLI smoke checks passed without login, provider downloads, or cloud requests.\n'
