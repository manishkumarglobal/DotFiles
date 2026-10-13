
# Autoload zsh modules when they are referenced
# zsh/stat provides its builtin as zstat, so it does not shadow /usr/bin/stat
zmodload -F zsh/stat b:zstat
zmodload -a zsh/zpty zpty
zmodload -a zsh/zprof zprof
#zmodload -ap zsh/mapfile mapfile
