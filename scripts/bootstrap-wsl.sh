#!/usr/bin/env bash
set -euo pipefail
trap 'printf "Installation failed at line %s. Resolve the error above before rerunning.\n" "$LINENO" >&2' ERR

if [[ "$(id -u)" -eq 0 ]]; then
    printf 'Run this as your normal WSL user, not root; sudo will be requested.\n' >&2
    exit 1
fi

source /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != 24.04 ]]; then
    printf 'This installer supports Ubuntu 24.04 only. Detected: %s %s.\n' "$ID" "$VERSION_ID" >&2
    exit 1
fi

architecture="$(dpkg --print-architecture)"
case "$architecture" in
    amd64) bicep_platform=linux-x64 ;;
    arm64) bicep_platform=linux-arm64 ;;
    *)
        printf 'Unsupported architecture: %s.\n' "$architecture" >&2
        exit 1
        ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname -- "$script_dir")"
printf 'One-time ONLINE setup: installing tools from signed vendor APT repositories.\n'
sudo -v
sudo apt-get update --error-on=any
sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg git
sudo install -d -m 0755 /etc/apt/keyrings

temp_dir="$(mktemp -d)"
cleanup() {
    rm -f -- "$temp_dir/hashicorp.asc" "$temp_dir/hashicorp.gpg" \
        "$temp_dir/microsoft.asc" "$temp_dir/microsoft.gpg" \
        "$temp_dir/github.gpg" "$temp_dir/bicep"
    rmdir -- "$temp_dir"
}
trap cleanup EXIT

curl --fail --silent --show-error --location --retry 3 \
    https://apt.releases.hashicorp.com/gpg -o "$temp_dir/hashicorp.asc"
gpg --batch --dearmor --output "$temp_dir/hashicorp.gpg" "$temp_dir/hashicorp.asc"
sudo install -m 0644 "$temp_dir/hashicorp.gpg" /etc/apt/keyrings/infra-starter-hashicorp.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/infra-starter-hashicorp.gpg] https://apt.releases.hashicorp.com noble main\n' "$architecture" \
    | sudo tee /etc/apt/sources.list.d/infra-starter-hashicorp.list > /dev/null

curl --fail --silent --show-error --location --retry 3 \
    https://packages.microsoft.com/keys/microsoft.asc -o "$temp_dir/microsoft.asc"
gpg --batch --dearmor --output "$temp_dir/microsoft.gpg" "$temp_dir/microsoft.asc"
sudo install -m 0644 "$temp_dir/microsoft.gpg" /etc/apt/keyrings/infra-starter-microsoft.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/infra-starter-microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main\n' "$architecture" \
    | sudo tee /etc/apt/sources.list.d/infra-starter-azure-cli.list > /dev/null

curl --fail --silent --show-error --location --retry 3 \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$temp_dir/github.gpg"
sudo install -m 0644 "$temp_dir/github.gpg" /etc/apt/keyrings/infra-starter-github.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/infra-starter-github.gpg] https://cli.github.com/packages stable main\n' "$architecture" \
    | sudo tee /etc/apt/sources.list.d/infra-starter-github-cli.list > /dev/null

sudo apt-get update --error-on=any
sudo apt-get install -y --no-install-recommends terraform azure-cli gh

curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/Azure/bicep/releases/latest/download/bicep-$bicep_platform" \
    -o "$temp_dir/bicep"
chmod 0755 "$temp_dir/bicep"
"$temp_dir/bicep" --version
sudo install -m 0755 "$temp_dir/bicep" /usr/local/bin/bicep

bash "$project_dir/.devcontainer/setup-user.sh"
bash "$project_dir/scripts/check-tools.sh"
printf '\nTool installation complete. Start a new Bash terminal to load the environment.\n'
printf 'Before going offline, finish the VS Code extension and project-cache steps in README.md.\n'
