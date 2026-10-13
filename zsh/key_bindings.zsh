
bindkey "^[[3~" delete-char

#bindkey '^r' history-incremental-search-backward
bindkey "^[[5~" up-line-or-history
bindkey "^[[6~" down-line-or-history
bindkey "^[[H" beginning-of-line
bindkey "^[[1~" beginning-of-line
bindkey "^[[F"  end-of-line
bindkey "^[[4~" end-of-line
bindkey ' ' magic-space    # also do history expansion on space
bindkey '^I' complete-word # complete on tab, leave expansion to _expand

# Up/Down search history for entries containing the typed text
# (zsh-history-substring-search). Both the normal and the application-mode
# sequences are bound, since oh-my-zsh switches zle into application mode.
if (( $+widgets[history-substring-search-up] )); then
    bindkey '^[[A' history-substring-search-up
    bindkey '^[[B' history-substring-search-down
    [[ -n $terminfo[kcuu1] ]] && bindkey "$terminfo[kcuu1]" history-substring-search-up
    [[ -n $terminfo[kcud1] ]] && bindkey "$terminfo[kcud1]" history-substring-search-down
fi
