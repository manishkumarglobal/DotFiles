# vim: ts=4 sw=4
# Initialize completion. This is the only place compinit runs: it must come
# after every fpath change and before anything that calls compdef directly.
#autoload -Uz bashcompinit
#bashcompinit

typeset -gU fpath

# Homebrew completions (brew, gh, rg, uv, ...), after the existing ones so they only fill gaps.
[[ -d /opt/homebrew/share/zsh/site-functions ]] && fpath+=(/opt/homebrew/share/zsh/site-functions)

# kubectl completion, regenerated only when the kubectl binary changes.
if (( $+commands[kubectl] )); then
    if [[ ! -s $ZSH_CACHE/completions/_kubectl || $commands[kubectl] -nt $ZSH_CACHE/completions/_kubectl ]]; then
        # Written outside completions/ first, so a failed run never leaves a bogus _* file there.
        if kubectl completion zsh >| $ZSH_CACHE/kubectl-completion.tmp 2>/dev/null; then
            command mv -f $ZSH_CACHE/kubectl-completion.tmp $ZSH_CACHE/completions/_kubectl
        else
            command rm -f $ZSH_CACHE/kubectl-completion.tmp
        fi
    fi
fi
fpath+=($ZSH_CACHE/completions)

autoload -Uz compinit
compinit -d "$ZSH_CACHE/zcompdump"

# Antigen's cache defers its own compinit to the first prompt; completion is
# already initialized, so drop that hook and register antigen's completion here.
if (( $+functions[_antigen_compinit] )); then
    autoload -Uz add-zsh-hook
    add-zsh-hook -d precmd _antigen_compinit
    unfunction _antigen_compinit
fi
(( $+functions[_antigen] )) && compdef _antigen antigen

# kustomize completion (vendored copy), only when kustomize is installed.
if (( $+commands[kustomize] )); then
    source ${ZSH_CONFIG_DIR:-${${(%):-%x}:A:h}}/kustomize_completion.zsh
    compdef _kustomize kustomize
fi
