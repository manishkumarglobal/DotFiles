# Load autojump when it is installed via Homebrew (its completion comes from
# Homebrew's site-functions, added to fpath in completion.zsh).
if [[ -f /opt/homebrew/etc/profile.d/autojump.sh ]]; then
    source /opt/homebrew/etc/profile.d/autojump.sh
fi
