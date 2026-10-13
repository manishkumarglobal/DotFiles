
HISTFILE=$HOME/.zhistory
HISTSIZE=1000000
SAVEHIST=1000000

HOSTNAME=$HOST

if [ -z "${STY}" -a -t 0 ]; then
    reattach () {
        if [ -n "${SSH_AUTH_SOCK}" ]; then
            ln -snf "${SSH_AUTH_SOCK}" "${HOME}/.ssh/agent-screen"
            SSH_AUTH_SOCK="${HOME}/.ssh/agent-screen" export SSH_AUTH_SOCK
        fi
        screen -A -D -RR ${1:+"$@"}
    }
fi

# Raise the soft open-files limit to at least 4096; never lower an inherited
# higher limit, and leave the hard limit alone.
if [[ $(ulimit -S -n) != unlimited ]] && (( $(ulimit -S -n) < 4096 )); then
    ulimit -S -n 4096
fi

export EDITOR=vim

export CLICOLOR=1
export LSCOLORS=GxFxCxDxBxegedabagaced

# Personal and Homebrew bins ahead of the system ones. Directories that do not
# exist are skipped, and typeset -U keeps the first copy of any repeated entry.
typeset -U path PATH
() {
    local -a front=(
        $HOME/Dropbox/bin
        /opt/homebrew/bin
        /opt/homebrew/sbin
        $HOME/.local/bin
        $HOME/nap/bin
        /usr/local/bin
        /usr/local/sbin
        /sbin
        /usr/sbin
    )
    path=(${^front}(N-/) $path)
}
