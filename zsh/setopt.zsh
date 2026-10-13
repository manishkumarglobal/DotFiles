
setopt APPEND_HISTORY
unsetopt BG_NICE        # do NOT nice bg commands
setopt CORRECT          # command CORRECTION
setopt EXTENDED_HISTORY     # puts timestamps in the history

setopt HIST_ALLOW_CLOBBER
setopt HIST_REDUCE_BLANKS
setopt INC_APPEND_HISTORY SHARE_HISTORY
setopt ALL_EXPORT

setopt MENUCOMPLETE
# Set/unset  shell options
setopt   notify correct pushdtohome cdablevars autolist
setopt   autocd recexact longlistjobs
setopt   autoresume histignoredups pushdsilent noclobber
setopt   autopushd pushdminus extendedglob rcquotes mailwarning
unsetopt bgnice autoparamslash
unsetopt ALL_EXPORT
