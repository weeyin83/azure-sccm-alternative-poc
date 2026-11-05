#!/usr/bin/env bash
set -euo pipefail
trap 'printf "User setup failed at line %s.\n" "$LINENO" >&2' ERR

mkdir -p "$HOME/.cache/terraform/plugins" "$HOME/.config/infra-starter"
cat > "$HOME/.config/infra-starter/env.sh" <<'EOF'
export TF_PLUGIN_CACHE_DIR="$HOME/.cache/terraform/plugins"
export CHECKPOINT_DISABLE=1
export AZURE_CORE_CHECK_VERSION=false
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no
export AZURE_BICEP_USE_BINARY_FROM_PATH=true
EOF

source_line='source "$HOME/.config/infra-starter/env.sh"'
touch "$HOME/.bashrc"
if ! grep -Fqx "$source_line" "$HOME/.bashrc"; then
    printf '\n%s\n' "$source_line" >> "$HOME/.bashrc"
fi

printf 'Configured Terraform cache and offline-friendly CLI defaults for Bash.\n'
