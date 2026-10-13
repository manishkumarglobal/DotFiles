#!/usr/bin/env bash
# Bootstrap the zsh setup on a new machine. Safe to re-run: existing files are
# never overwritten.
set -euo pipefail

ZSH_DIR="$(cd "$(dirname "$0")" && pwd)"

# Antigen, pinned to the release in use and verified before it is installed.
ANTIGEN_URL="https://raw.githubusercontent.com/zsh-users/antigen/v2.2.2/bin/antigen.zsh"
ANTIGEN_SHA256="3fc9472388232ecb7cf2c6d28f06109d857afa1c1897ce1bbeed40aced6e6518"

if [[ -f "$HOME/antigen.zsh" ]]; then
    echo "~/antigen.zsh already exists, leaving it alone."
else
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL "$ANTIGEN_URL" -o "$tmp"
    echo "$ANTIGEN_SHA256  $tmp" | shasum -a 256 -c - >/dev/null
    mv "$tmp" "$HOME/antigen.zsh"
    echo "Installed ~/antigen.zsh (v2.2.2)."
fi

## Add command to install autojump here (brew install autojump)

# Point ~/.zshrc at this repository's zshrc.
if [[ -L "$HOME/.zshrc" && "$(readlink "$HOME/.zshrc")" == "$ZSH_DIR/zshrc" ]]; then
    echo "~/.zshrc already links to $ZSH_DIR/zshrc."
elif [[ -e "$HOME/.zshrc" || -L "$HOME/.zshrc" ]]; then
    echo "~/.zshrc already exists and is not this repo's zshrc; move it aside and re-run." >&2
    exit 1
else
    ln -s "$ZSH_DIR/zshrc" "$HOME/.zshrc"
    echo "Linked ~/.zshrc to $ZSH_DIR/zshrc."
fi
