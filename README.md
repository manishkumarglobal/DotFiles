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

`global-claude/hooks/claude-turn-notify.sh` sends a FirstMate alert when a Claude Code session in WezTerm or tmux is ready, has failed, or needs input.
It stays silent while sub-agents or background work are still running.
`global-claude/settings.json` wires it to the `UserPromptSubmit`, `Stop`, `StopFailure` and `Notification` events.
Clicking an alert runs `global-claude/bin/claude-session-jump`, which brings the session's tab to the front.

To restore it on this Mac:

* Copy the hook and its test to `~/.claude/hooks/` and the jump helper to `~/.local/bin/`, keeping them executable.
* Make sure the four hook entries in `~/.claude/settings.json` match the ones in `global-claude/settings.json`.
* Rebuild the click handler, which macOS needs because a clicked notification opens a URL.
  Compile `global-claude/bin/claude-session-jump.applescript` with `osacompile` into `~/Applications/Claude Session Jump.app`.
  In its `Info.plist`, set `CFBundleIdentifier` to `dev.napsterx.claude-session-jump`, set `LSUIElement` to true, and add a `CFBundleURLTypes` entry whose scheme is `claudejump`.
  Re-sign it ad hoc (`codesign --force --sign -`) and open it once so macOS registers the scheme.
  These are the installed handler's settings; the rebuild itself has not been rehearsed.
* Run the tests: `cd ~/.claude/hooks && bash claude-turn-notify.test.sh "$PWD/claude-turn-notify.sh" ~/.local/bin/claude-session-jump </dev/null` (it takes a few minutes).

FirstMate itself, with its logo, is not kept here.

`scripts/backup.sh` copies `~/.claude` here, then commits and pushes on its own.
It leaves out logs, runtime state and dated safety copies (`*.before-*`); `bash tests/backup_test.sh` checks that.
