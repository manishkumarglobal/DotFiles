# DotFiles
My Custom configs for Zsh/Vim/Screen etc

ZSH:

A lot of configs are stolen from different places, 
but I just wanted one place where I could keep all of this stuff, and don't need to do configurations everytime on new machine

It uses Antigen plugin manager, which in-turn uses oh-my-zsh also

* Steps need to take care to make it work.

  * Make sure ZSH is installed on the machine
  * mkdir git; cd git
  * git clone https://github.com/manishkumarglobal/DotFiles.git
  * bash ~/git/DotFiles/zsh/commands.sh
    * Installs Antigen v2.2.2 (checksum-verified) to ~/antigen.zsh and links ~/.zshrc to this repo's zshrc.
    * Safe to re-run; it never overwrites an existing ~/antigen.zsh or ~/.zshrc.

The completion dump and generated completions are cached in ~/.cache/zsh (or $XDG_CACHE_HOME/zsh).
If completions look stale, delete that directory and run `antigen reset`, then open a new shell.


Install fonts from https://github.com/powerline/fonts

That's it. You are all set to enjoy ZSH

## WezTerm

`wezterm.lua` is the WezTerm config; link it with `ln -s ~/git/DotFiles/wezterm.lua ~/.config/wezterm/wezterm.lua`.
When the tab bar is full, the active tab keeps its whole title and the other tabs shrink to fit.
The tab bar logic has tests that run the real config through WezTerm's tab bar layout steps.
Run them with `luajit tests/wezterm_tab_bar_test.lua` (LuaJIT from Homebrew: `brew install luajit`).

## Claude Code alerts

The alert hook sends a FirstMate alert when a Claude Code session in WezTerm or tmux is ready, has failed, or needs input.
It is not kept here.
EngineeringToolsMK owns it, with its tests, the click-to-tab helper and handler, and the relay that brings `mk-agent` sessions' alerts to this account, under `tools/turn-alerts`.
Its `install.py` installs and checks all of it, and its README is the restore procedure.
`scripts/backup.sh` skips the installed hook and its tests for that reason.

Two parts of the setup stay here:

* `global-claude/settings.json` wires the hook to the `UserPromptSubmit`, `Stop`, `StopFailure` and `Notification` events. `install.py` never writes that file, and its `check` fails until the wiring is there.
* `global-claude/hooks/turn-notify-ignore` lists tmux sessions that never alert. Copy it to `~/.claude/hooks/`.

FirstMate keeps every alert it has shown, so `global-claude/bin/firstmate-trim` deletes anything older than 24 hours from its folders and from the hook's log.
The queue of alerts not yet shown is never touched.
The LaunchAgent `global-claude/launchagents/com.mk-global.firstmate-trim.plist` runs it hourly and at login.
To restore it, copy the script to `~/.local/bin/` (executable) and the plist to `~/Library/LaunchAgents/`, then run `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mk-global.firstmate-trim.plist`.
`bash tests/firstmate_trim_test.sh` checks it.

FirstMate itself, with its logo, is not kept here.

`scripts/backup.sh` copies `~/.claude` here, then commits and pushes on its own.
It leaves out logs, runtime state and dated safety copies (`*.before-*`); `bash tests/backup_test.sh` checks that.
