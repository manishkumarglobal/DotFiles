# Zsh Configuration Audit Report

Date: 2026-10-13.
Scope: `zsh/` in this repository, plus the runtime pieces it depends on (`/etc/zshrc`, `/etc/zprofile`, Antigen and its cache, NVM, Homebrew).
Machine: macOS on Apple Silicon, zsh 5.9, WezTerm.
Nothing has been committed, pushed, or opened as a PR.

Explicit exclusions honored throughout: `00-early.zsh` stays unsourced, `~/.profile` sourcing is unchanged, `HISTSIZE`/`SAVEHIST` stay at 1,000,000, and the 13 Antigen bundles are untouched.

## 1. Executive summary

The configuration worked on the surface, but it carried several silent defects that had masked each other for years.
Completion was initialized three times against three different dump files.
One of those files (`/zcompdump`) could never be written, so a full dump was regenerated on every startup.
That one problem accounted for roughly three quarters of all measured shell-function time at startup.
The Dropbox PATH entry was quoted, so `~` never expanded and nothing in that directory could be found.
`setopt extendedglob` silently broke NVM: every alias-based operation (`default`, `node`, `lts/*`) failed, so the configured default never applied.
Several style rules, a key-binding plugin, and a terminal setting looked active but had never taken effect.
A database password from 2018 is still in the public Git history.

After remediation:
- A fresh shell starts with no warnings.
- Completion is initialized exactly once, against a private, persistent cache.
- PATH is deterministic and has no duplicates.
- Plain startup (`zsh -lic exit`) is about three times faster.
- Time until the prompt is usable improved about 1.8 times; most of the remainder is the agnoster prompt's git segment.

An independent post-fix audit, run by a separate agent with no access to the remediation reasoning, found one ordering regression that this remediation had introduced, along with several pre-existing issues.
All confirmed defects from that audit were fixed and covered by regression tests.
All 59 scripted runtime checks, 11 audit-regression checks, 12 interactive terminal checks, and the robustness checks pass.

The configuration is safe for everyday use.
The remaining items are decisions and low-severity improvements, listed in sections 4 and 8.
One of them, rotating the historical password, needs action from you.

## 2. Before-and-after comparison

### Startup performance

Every figure is the median of repeated runs, with warm-up runs excluded and the range in parentheses.
The "before" configuration was reconstructed from the last commit in an isolated scratch copy, so both sides ran on the same machine minutes apart.
These are the final paired runs, taken after all fixes.

| Measurement | Before | After |
| --- | --- | --- |
| `zsh -lic exit`, clean launchd-like environment (n=15) | 329 ms (312 to 368) | 112 ms (108 to 128) |
| `zsh -lic exit`, inherited session environment (n=11) | 291 ms (274 to 329) | 85 ms (81 to 98) |
| Time until the line editor is ready, real pseudo-terminal, inside a git repository (n=15) | 486 ms (464 to 532) | 263 ms (246 to 289) |

`zsh -lic exit` exits before the first prompt, so it never paid for Antigen's deferred first-prompt `compinit`.
That's why the time-to-interactive measurement was added.
Measurements varied by about 15 percent between sessions.
For example, an earlier paired time-to-interactive run measured 579 ms (523 to 617) before and 283 ms (272 to 327) after.
The 714 ms figure in the original brief could not be reproduced on a warm machine.
An early clean-environment run in this session measured 425 ms (380 to 469), and the brief's figure most likely captured a cold start, such as an Antigen cache rebuild.

Profiled shell-function time through the first prompt:

| Item | Before | After |
| --- | --- | --- |
| `compinit` calls | 3 | 1 |
| `compinit` total time | about 364 ms | about 20 ms |
| Completion dump rewrites per startup | 2 | 0 |
| `compdef` calls at startup | 1,979 | 0 (kubectl completion is now autoloaded) |
| NVM at startup | about 54 ms | not activated (see 3.4) |

About 130 to 150 ms of the remaining time-to-interactive is the agnoster theme's git segment, which runs on every prompt inside a git repository (finding R3).

### PATH

| Property | Before | After |
| --- | --- | --- |
| Entries | 43 | 17 |
| Duplicate entries | 4 | 0 |
| Nonexistent directories added by this repository | 7 (MacPorts, Python 2.7 and 3.6, MySQL, RVM, `/usr/local/sbin`, and the literal `~/Dropbox/bin`) | 0 |
| Antigen plugin directories | 14 (exposing stray scripts such as `update`) | 0 |
| Literal `~` entry | yes | no |
| Trailing-slash variants (`/opt/homebrew/bin/` and `/opt/homebrew/bin`) | yes | no |
| `usvpn` (Dropbox bin) resolvable | no | yes |

Five nonexistent entries remain.
All five come from macOS-owned files in `/etc/paths.d` (`10-cryptex`, `10-pmk-global`, `100-rvictl`), outside this repository.

### Completion behavior

| Behavior | Before | After |
| --- | --- | --- |
| Dump location | `/zcompdump` (unwritable), `~/.zcompdump`, `~/.antigen/.zcompdump` | `~/.cache/zsh/zcompdump`, in a mode-700 directory |
| Results cache (`use-cache`) | `~/.zsh/cache/$HOST` (did not exist) | `~/.cache/zsh/compcache` |
| Homebrew completions (`brew`, `gh`, `rg`, `uv`, `wezterm`, `cargo`, and others) | absent | available |
| Host completion | mangled entries such as `apiaryone.local#Local` and `Site` | zsh's own `/etc/hosts` and ssh parsing |
| Dash-aware matching (`f-b` to `foo-bar`) | silently overridden | restored as a fallback after case-insensitive matching |
| Kustomize completion | sourced every startup, never registered | loaded and registered only when `kustomize` is installed |
| `killall`/`pkill` process-name completion | offered a bogus `COMMAND` entry | header suppressed |

### Startup warnings

No warnings or errors were printed before or after.
Before, that silence was partly accidental: `stty erase ^H` was being glob-expanded (see 3.8), and its error was discarded.

### Other meaningful changes

- A higher inherited open-files limit is no longer cut down: this session inherits 1,048,576, and the old configuration reduced it to 4,096.
- NVM aliases work again, while `node` stays Homebrew's v26.7.0, as you chose.
- Up and Down now search history by substring, as you chose.

## 3. Fixes implemented

### 3.1 Dropbox PATH

**Original problem.**
`~/Dropbox/bin` was inside double quotes, so the tilde never expanded and the entry pointed at a directory literally named `~`.

**Root cause.**
Tilde expansion does not happen inside quotes.

**Files changed.**
`zsh/variables.zsh`, `zsh/zshrc`.

**What changed.**
PATH is now built from a declared priority list using zsh's native `path` array.
Only directories that exist are kept, and `typeset -U` drops repeated entries so that the first occurrence wins.
The PATH builder runs right after Antigen, so every later tool check sees the final PATH.
The entry uses `$HOME/Dropbox/bin` rather than the CloudStorage path.
`~/Dropbox` is a symlink to `~/Library/CloudStorage/Dropbox`, so both name the same directory, and `~/Dropbox` also works with Dropbox installs that don't use File Provider.
Per your decision, Dropbox stays ahead of Homebrew and the system directories.
Only the user-owned bun and `~/.local/bin` directories come before it, exactly as before.

**Validation.**
- `usvpn` resolves to `$HOME/Dropbox/bin/usvpn` in a fresh login shell.
- There are no duplicate or trailing-slash entries.
- Homebrew stays ahead of `/usr/bin`.
- A nested interactive shell keeps the same entry count.

**Behavioral impact.**
Dropbox tools now resolve, and the dead MacPorts, Python 2.7/3.6, MySQL, and RVM entries are gone.
Shells started inside an already-open session inherit its old PATH, including the literal `~` entry, until WezTerm is restarted.

### 3.2 Completion initialization and caching

**Original problem.**
`completion.zsh` and `variables.zsh` each ran `compinit`, and Antigen's cache registered a first-prompt hook that ran it a third time.

**Root cause.**
`ZSH_CACHE` was only ever set by the unsourced `00-early.zsh`, so `completion.zsh` dumped to `/zcompdump`.
That path is unwritable, so the dump was regenerated on every startup.
The other two calls used different dump files with different `fpath` snapshots, so they could not reuse each other's work.

**Files changed.**
`zsh/zshrc`, `zsh/completion.zsh`, `zsh/variables.zsh`.

**What changed.**
`zshrc` defines `ZSH_CACHE` as `${XDG_CACHE_HOME:-$HOME/.cache}/zsh`, created with mode 700 before anything uses it.
`completion.zsh` is now the single owner of completion:
- It finalizes `fpath`, appending Homebrew's site-functions so existing completions keep priority and adding a cached kubectl completion.
- It runs `compinit` once.
- It then removes Antigen's deferred hook and registers Antigen's own completion directly.

The hook removal is guarded, so if Antigen ever changes, the worst case is a second, correct `compinit`.
Antigen keeps its own dump file in `~/.antigen`, which it writes only during cache rebuilds.

An earlier iteration of this fix had the shell and Antigen share one dump file.
That produced a real race, observed directly: Antigen's background `zcompile` left a stale compiled dump that lacked the Homebrew and kubectl entries.
The two files were separated so that each has exactly one writer.

**Validation.**
- zprof shows exactly one `compinit` call.
- A fresh `XDG_CACHE_HOME` gets a mode-700 cache created automatically.
- Real TAB presses in a pseudo-terminal complete `git`, `kubectl`, `k`, `brew`, and `gh` subcommands.

**Behavioral impact.**
Homebrew-provided completions now work, and everything that completed before still completes.

### 3.3 Kubectl and Kustomize completion

**Original problem.**
`source <(kubectl completion zsh)` spawned kubectl (about 35 ms) and replayed 1,979 `compdef` calls on every startup.
The 26 KB `kustomize_completion.zsh` was sourced on every startup, although `kustomize` is not installed.
It also never called `compdef`, so it could not have worked even with `kustomize` installed.

**Files changed.**
`zsh/completion.zsh`, `zsh/zshrc`.

**What changed.**
kubectl's completion is generated into a temporary file outside the completions directory, then moved into `~/.cache/zsh/completions/_kubectl`.
If generation fails, the temporary file is removed.
The completion is autoloaded from `fpath` and regenerated only when the kubectl binary is newer or the cached file is empty.
Kustomize completion is sourced and registered only when `kustomize` exists.

**Validation.**
- The cache regenerated when made stale and when emptied, and was left untouched when fresh.
- A failing kubectl stub left no completer and no temporary file behind.
- `kubectl versio<TAB>` and `k versio<TAB>` complete.

### 3.4 NVM

**Original problem.**
`nvm alias default 22` never applied, and every shell used Homebrew's Node v26.7.0.

**Root cause.**
NVM strips comments from alias files with a `#*` pattern, which zsh rejects as a bad pattern under `extendedglob`.
Bisecting the shell options confirmed that `extendedglob` alone causes the failure.

**Files changed.**
`zsh/zshrc`.

**What changed.**
Per your decision, NVM loads with `--no-use`, so `node` stays Homebrew's v26.7.0, exactly as you have been running it.
`--no-use` also skips NVM's automatic `.nvmrc` activation when a shell starts in a project directory; `nvm use` in that directory still works.
Every `nvm` command runs through a thin wrapper that disables `extendedglob` for that call only.
NVM's script is parsed with alias expansion off, so Oh My Zsh's `grep` alias is no longer baked into NVM's 122 internal functions.
The `nvm bash_completion` line was removed.
That file does not exist in this install, and if it ever appeared, it would run its own `compinit`.

**Validation.**
- `nvm current` is `system`.
- `nvm version default` resolves to v22.
- `nvm use 20` and `nvm use default` switch Node.
- `extendedglob` is still on afterwards.
- No NVM function contains the alias text.

The independent audit reported the wrapper as unnecessary.
That did not reproduce: in the configured shell, NVM's internal alias function still fails with "bad pattern".
The unwrapped entry point only appears to work because NVM calls itself recursively, and those inner calls go through the wrapper.

**Behavioral impact.**
NVM aliases work again, and NVM no longer costs about 54 ms at startup.
`node` is unchanged.

### 3.5 Zsh styles

**Original problem.**
`zstyles.zsh` defined many styles two or three times, so the earlier definitions were dead, and several rules never worked at all.

**Files changed.**
`zsh/zstyles.zsh`.

**What changed.**
Each style is now defined once, keeping the value that was actually in effect, so the visible completion UI is unchanged.
Specific corrections:
- Three conflicting cache settings became one, under `ZSH_CACHE`.
- The `max-errors` comment said "one error per three characters", while the effective rule allowed one per two. The effective rule was kept and the comment corrected.
- The case-insensitive matcher had overwritten the dash-aware one. Both now apply, case-insensitive first.
- The `hosts` style was set twice, with opposite intent. The definition that won parsed `/etc/hosts` with a buggy `awk` that fused fields and comments into fake host names. Both were removed, so zsh's own parser now handles `/etc/hosts` and ssh hosts, and two subprocesses are gone.
- `sched 0 _set-list-colors` duplicated a direct `list-colors` definition, because Oh My Zsh sets `LS_COLORS` first, so it was removed.
- The `(^rm)` ignored-patterns rule never worked, because `extendedglob` was off when it was defined. It was dropped rather than revived, because reviving it would newly hide `*.pro` (Qt project) and `*.old` files from completion.
- The malformed `menu select=1 _complete _ignored _approximate` value was removed.
- The overridden `ps -axw` process command was removed.
- The duplicated completer list was removed.
- An `expand` tag-order setting for a completer that is not enabled was removed.
- `processes-names` used the GNU `h` flag, which macOS `ps` ignores, so `killall` completion offered `COMMAND`. It now uses `command=`.

**Validation.**
Effective values were probed with `zstyle -s` and `zstyle -a` in a fresh shell.
TAB completion was exercised for case-insensitive matching (`foob` to `FooBar-baz`) and dash-aware matching (`f-b` to `FooBar-baz`).

### 3.6 Startup performance

Beyond 3.2 to 3.4:
- The `hostname` and `scutil` subprocesses (about 11 ms) were replaced by zsh's built-in `$HOST`.
- `SHORT_HOST` was unused by any loaded code and was dropped.
- `promptinit` and `compaudit` calls with no consumer were dropped.
- The direnv hook is now guarded by command presence instead of a hardcoded path.

**Validation.**
See the tables in section 2.

### 3.7 Hardcoded paths and legacy configuration

**Files changed.**
`zsh/zshrc`, `zsh/variables.zsh`, `zsh/autojump.zsh`, `zsh/aliases.zsh`, `README.md`.

**What changed.**
- `zshrc` resolves its own directory through the `~/.zshrc` symlink, replacing a dozen hardcoded `~/git/DotFiles/zsh` paths.
- The `/Users/manish` paths for bun, gcloud, and the `cl` alias became `$HOME`.
- An exported `PYTHONPATH` pointing at a nonexistent MacPorts Python 2.7 directory was removed. It would have leaked into every Python 3 process.
- `TZ="Asia/Calcutta"` was removed. It was never exported, so it had no effect; the system zone is already `Asia/Kolkata`, and `Asia/Calcutta` is a deprecated alias.
- The MacPorts autojump loader also exported a nonexistent directory into `FPATH`. It was replaced with one that loads autojump from Homebrew, if installed.
- The open-files limit is now raised to at least 4,096 but never lowered. Before, `ulimit -n 4096` silently cut the inherited 1,048,576.
- The Instart-era settings were removed: `v`, `h`, `VAULT_ADDR`, `NOMAD_ADDR`, `NOMAD_SKIP_VERIFY`, and the OpsDB password. See section 5.
- The README clone URL now points at this repository's actual remote.
- The `nap/bin` entry was kept, because it still holds tools including `nomad`, `kubectx`, and `oath`.

**Evidence.**
The shell history begins in April 2026, when this machine was set up.
Since then it shows zero uses of Nomad, Vault, MacPorts, `smcli`, `glist`, `grp`, `dmesg`, `bypass`, `afk`, or `ifactive`.

### 3.8 Terminal erase key

**Original problem.**
`stty erase ^H &>/dev/null` ran after `setopt extendedglob`, so `^H` was a glob meaning "every file except `H`" in the current directory.
In a typical directory it expanded to many file names, so `stty` failed and the error was discarded.
In a directory containing exactly one single-character file name, it could set the erase key to that character.

**Files changed.**
`zsh/variables.zsh`.

**What changed.**
The line was removed.

**Validation.**
The erase key in a fresh pseudo-terminal is `^?`, matching WezTerm's Backspace.
Startup is silent from your home directory, from an empty directory, and from a directory containing a file named `H`.

**Behavioral impact.**
None in practice, because the line never worked as intended.

### 3.9 Aliases, functions, and modules

**Files changed.**
`zsh/aliases.zsh`, `zsh/modules.zsh`, `zsh/zshrc`.

**What changed.**
- `grp` was `git reset --hard HEAD~1 ; git pull`. That discarded uncommitted work irrecoverably and pulled even if the reset failed. It is now `git reset --keep HEAD~1 && git pull`: `--keep` refuses to overwrite local changes, the dropped commit stays in the reflog, and the pull runs only if the reset succeeded.
- `dmesg` was aliased to GNU-only flags that macOS `dmesg` rejects, so the alias made `dmesg` always fail. It was removed.
- `bypass` (its Time Machine kext was removed from macOS), `port` (MacPorts is not installed), `glist` (it points into another user's home directory), and `smcli` (the Review Board tools are not installed) pointed at targets that no longer exist. They were removed.
- `ifactive` depended on `pcregrep`, which is not installed. It is now a function using macOS `awk`, with the same output.
- `afk` pointed at `CGSession`, which no longer exists on current macOS. It now uses `pmset displaysleepnow`, which locks the screen when a password is required immediately after sleep.
- `modules.zsh` autoloaded zsh's `stat` builtin under the name `stat`. That silently shadowed `/usr/bin/stat` with an incompatible syntax. The builtin is now exposed as `zstat`, as the zsh documentation recommends.
- Aliases are now defined last in `zshrc`. That way, neither your aliases nor the global `gi` alias expand inside NVM, bun, gcloud, or other third-party scripts sourced earlier. Your aliases still override Oh My Zsh's.

**Validation.**
- Alias definitions were checked in a fresh shell.
- `ifactive` and `ips` were run; both are read-only.
- `stat` resolves to `/usr/bin/stat`, with `zstat` available.
- The global `gi` alias and your `grep` alias are still in effect.

`grp`, `afk`, `flush`, `show`, and `hide` were not executed, because they change state.

### 3.10 Key bindings

**Original problem.**
The `zsh-history-substring-search` bundle was loaded, but nothing bound keys to it, so it did nothing.

**Files changed.**
`zsh/key_bindings.zsh`.

**What changed.**
Per your decision, Up and Down are bound to substring search in both normal and application cursor-key modes.
The bindings are guarded on the widget existing.

**Validation.**
In a real pseudo-terminal with an isolated history file, typing part of a command and pressing Up recalled the matching entry, with both `^[[A` and `^[OA`.
Home, End, and Delete still work.

**Behavioral impact.**
Up and Down now match text anywhere in a history entry, instead of only at the start.

### 3.11 Antigen plugin directories on PATH

**Original problem.**
Antigen appended all 14 bundle directories to PATH.
This made stray plugin files resolvable as commands.
`update` ran the iterm2 plugin's script, which downloads a file into the current directory, and `nroff` resolved to a colored-man-pages shim.

**Root cause.**
This is Antigen's default behavior.
None of the loaded bundles needs PATH, because they load through `fpath` and `source`.

**Files changed.**
`zsh/zshrc`.

**What changed.**
Right after `antigen apply`, the bundle directories are removed from PATH.
The bundles themselves are unchanged.

**Validation.**
- `update` no longer resolves.
- No bundle directory remains on PATH.
- The Antigen bundle list is identical to the original.
- All completion and key-binding tests pass.

### 3.12 Installer and README

**Original problem.**
`commands.sh` wrapped each command in backticks, which executes the command's output as another command.
It downloaded Antigen from `git.io`, a frozen URL shortener, with no version pin and no integrity check.
Its `ln -s` failed on re-run, and the README told you to run the same `ln -s` again.

**Files changed.**
`zsh/commands.sh`, `README.md`.

**What changed.**
- The installer uses `set -euo pipefail`.
- It downloads Antigen v2.2.2 from a pinned GitHub tag and verifies the SHA-256 before installing.
- It never overwrites an existing `~/antigen.zsh` or `~/.zshrc`, and it is safe to re-run.
- The pinned file was verified to be byte-identical to the installed `~/antigen.zsh`.
- The README documents what the installer does and where the cache lives.

**Validation.**
- `bash -n` syntax check.
- The pinned URL and checksum were verified by downloading into an isolated scratch directory.
- The installer was not run against this machine, as instructed.

## 4. Remaining findings

Findings come from this remediation and from the independent audit, merged and de-duplicated.
"Confirmed" means reproduced or measured in this session.
"Potential" means inferred by reading.

| ID | Severity | Finding | Evidence | Impact | Recommended action | Needs your decision |
| --- | --- | --- | --- | --- | --- | --- |
| R1 | Medium | Global alias `gi` expands anywhere on a command line, not just at the end. | Confirmed: it rewrote a test command into a broken pipe into `grep`, and the auditor reproduced `git log --grep gi` failing. | Any bare `gi` word, such as a search term or file name, silently becomes `\| grep -i`. It no longer leaks into sourced scripts (fixed in 3.9). | Replace it with a regular alias or a function, or remove it. | Yes |
| R2 | Medium | `~/Dropbox/bin` is ahead of Homebrew and system directories, by your choice. | Confirmed PATH order. | Anything synced into that folder can shadow `git`, `ssh`, or `sudo`. | Move it after the system directories, or call its tools by full path. | Yes |
| R3 | Medium | The agnoster prompt's git segment is slow inside repositories. | Measured 129 to 151 ms per prompt in this repository, against 22 ms outside one. It comes from `vcs_info` with `check-for-changes` making several git calls. | It adds latency to every prompt in a git repository, growing with repository size. | Switch to an async git prompt, or turn off change detection in the theme's `vcs_info`. | Yes (prompt UX) |
| R4 | Medium | `extendedglob` makes `^` a glob operator. | Confirmed: `git rev-parse HEAD^` fails with "no matches found". | Common git revision syntax must be quoted. | Add `alias git='noglob git'`, or quote revisions. | Yes |
| R5 | Medium | `globdots` makes `*` match dotfiles. | Confirmed: `print *` lists `.hidden`. | `rm -rf *` or `mv * dest` also hits `.git` and `.env`. | Remove `globdots`, and use `*(D)` when you want dotfiles. | Yes |
| R6 | Medium | `correctall` offers to "correct" new file names. | Confirmed: `mkdir notez` prompted "correct 'notez' to 'notes'". | A reflexive `y` sends `mv`, `cp`, or `mkdir` to an existing path. | Drop `correctall` and keep `correct`. | Yes |
| R7 | Low | PATH is configured only for interactive shells. | Confirmed: `zsh -c` sees only `/usr/bin:/bin:/usr/sbin:/sbin`. | Scripts and GUI-launched tools don't see Homebrew, Dropbox, or `~/.local/bin`. | Move the PATH builder into a repository-managed `~/.zprofile`, so it runs after macOS's `path_helper`. | No |
| R8 | Low | Re-sourcing `~/.zshrc` in a running shell is not idempotent. | Confirmed by the auditor: it runs `compinit` twice, prints an Antigen "already installed" message 15 times, and drops one Oh My Zsh prompt hook. | Confusing output and a degraded terminal title after `source ~/.zshrc`. | Use `exec zsh` to reload. | No |
| R9 | Low | Startups that rebuild Antigen's cache run `compinit` twice. | Confirmed by the auditor on a scratch copy of the Antigen directory. | Only the first start after a `zshrc` edit or `antigen reset` is slower. | Accept; this is Antigen's uncached path. | No |
| R10 | Low | Some Oh My Zsh completion registrations are lost (`d`, `ggp`, `cpv`, `omz`). | Confirmed by the auditor: Antigen's cache stubs `compdef` while loading plugins. This predates the remediation. | Those few commands have no TAB completion. | Re-register the ones you use after `compinit`, if any. | No |
| R11 | Low | `setopt.zsh` has redundant or conflicting options. | Confirmed by reading and by the manual: `INC_APPEND_HISTORY` with `SHARE_HISTORY` (the manual says to turn the first off), `CORRECT` and `BG_NICE` each set twice, `ALL_EXPORT` toggled around nothing, the default `APPEND_HISTORY`, `mailwarning`, and `cdablevars` with `autocd`. | Clutter, plus one documented history-option conflict. | Tidy up together with R4 to R6. | Yes (options are preferences) |
| R12 | Low | The color block in `extra.zsh` is mostly dead. | Confirmed: `autoload colors zsh/terminfo` creates a bogus function, `colors` runs twice, `count` and `color` leak, and the `PR_*` variables are used only by the unsourced `hashed.zsh`. | Minor clutter and namespace pollution. | Remove the block, or keep only `autoload -U colors && colors`. | No |
| R13 | Low | Your aliases override Oh My Zsh's. | Confirmed: `grep` loses the `.idea`, `.tox`, `.venv`, and `venv` excludes; `gg` replaces `git gui citool`; `ping` uses `-c 100000`; `path` replaces `print -l $path`. | Possibly unintended differences. | Confirm each one is intended. | Yes |
| R14 | Low | Tab is bound to `complete-word`, and the comment says expansion is left to `_expand`, but `_expand` is not an enabled completer. | Potential, by reading. | Tab never expands globs or variables. | Add `_expand` to the completer list, or fix the comment. | No |
| R15 | Low | `LSCOLORS` (used by `ls`) and `LS_COLORS` (used by completion, from Oh My Zsh's defaults) differ. | Potential, by reading. | `ls` output and completion lists use different colors. | Define `LS_COLORS` to match, if you care. | No |
| R16 | Low | PATH is still edited in four places: `variables.zsh`, plus the `~/.local/bin`, bun, and gcloud blocks in `zshrc`. | Confirmed. | The final order is bun, `~/.local/bin`, Dropbox, and so on, not exactly the list in `variables.zsh`. | Leave the installer-managed blocks alone, or fold them into `variables.zsh` and accept that installers may re-add them. | No |
| R17 | Low | The gcloud lines point at `~/Downloads/google-cloud-sdk`, which does not exist. | Confirmed: gcloud is not installed anywhere `mdfind` can see. | The lines are dead; they are guarded, so harmless. | Reinstall the SDK at a stable path, or remove the lines. | Yes |
| R18 | Low | A missing `~/antigen.zsh` is not handled. | Confirmed by the auditor with a fake home directory: "no such file" plus four "command not found" errors. | A noisy first start on a fresh machine before `commands.sh` runs. | Guard the Antigen block with a readability check. | No |
| R19 | Low | `flush` likely needs `sudo`. | Potential: mDNSResponder runs as another user; this was not executed. | `killall -HUP` fails without privileges. | Prefix the `killall` with `sudo`. | No |
| R20 | Info | Some aliases are fragile. | By reading: `localip` hardcodes `en0`, `ip` depends on OpenDNS and would shadow iproute2mac's `ip`, `cl` duplicates `claude`, and `alias -s rb=vim` opens `.rb` scripts in vim instead of running them. | Surprising in edge cases. | Review at leisure. | No |
| R21 | Low | Leftover artifacts. | Confirmed: a stale `~/.zcompdump`; `~/.antigen/debug.log` is 1.3 MB and grows about 106 KB per cache rebuild. | Disk clutter only. | Delete `~/.zcompdump`; optionally set `ANTIGEN_DEBUG_LOG=/dev/null`. | No |
| R22 | Info | Several files are inactive. | Confirmed. Not sourced: `functions.zsh` (needs the uninstalled `powerline-shell`, and would override `SSH_AUTH_SOCK`), `hashed.zsh` (comments only), `custom_agnoster-theme.zsh`. Sourced but empty: `plugins_configs.zsh`. Dormant: `autojump.zsh` (autojump is not installed) and `kustomize_completion.zsh` (kustomize is not installed). | No runtime effect. | Keep or delete; this audit deleted nothing. | Yes |
| R23 | Info | Antigen compiles `~/.zshrc` into `~/.zshrc.zwc`, and zsh prefers that compiled copy when it is newer than the source. | By reading, and noted by the auditor. | Restoring an older `zshrc` while preserving its timestamp could run stale code. `git checkout` sets a fresh timestamp, so normal rollback is safe. | If behavior ever looks stale, delete `~/.zshrc.zwc`. | No |
| R24 | Low | `commands.sh` has a few gaps. | By reading: it doesn't check that `git` and `curl` exist, it derives the repository path from `$0`, which doesn't work under `curl \| bash` (not a supported mode), and the autojump install is still a TODO. | Weak error messages on a bare machine. | Add the presence checks if you bootstrap new machines often. | No |
| R25 | Info | NVM has no TAB completion. | Confirmed: NVM's `bash_completion` file is absent from this install. | `nvm <TAB>` offers file names. | Optional. | No |
| R27 | Low | The PATH builder drops directories that do not exist at startup. | Potential, by reading: this is a new failure mode compared with the old unconditional string. | If `~/Library/CloudStorage/Dropbox` were not mounted yet at login, that shell would lack `~/Dropbox/bin` until a new shell is opened. | Accept (low likelihood), or add Dropbox without the existence filter. | No |
| R26 | Info | Existing terminal sessions keep the old PATH. | Confirmed: nested shells inherit the literal `~` entry. | It persists until those sessions end. | Restart WezTerm. | No |

## 5. Security findings

**Committed credential in public history (action required).**
`I10C_OPSDB_PASSWORD` was committed to `zsh/variables.zsh` on 2018-01-30, in commit `41a9d54`.
It also appears in later history, including commits `9b47d24` and `295232c`.
The repository is public on GitHub, so treat the value as exposed.
It is removed from the working tree by this change, but it stays at the tip of `master` until you commit.
It also stays in history permanently unless you rewrite history.
If that database, or any system that reused the password, still exists, rotate it.
Removing the value from history requires a rewrite (for example, `git filter-repo`) and a force push.
This audit did neither.
Because the value is already public, rotation matters more than the rewrite.
The value is not reproduced in this report or in any command output from this session.

**TLS verification bypass (fixed in the working tree).**
`NOMAD_SKIP_VERIFY=1` disabled certificate verification for every `nomad` command in every shell, not only for the old Instart cluster in `NOMAD_ADDR`.
A `nomad` binary still exists in `~/nap/bin`, so the bypass applied to any cluster that binary was pointed at.
It was removed, along with the obsolete `NOMAD_ADDR` and `VAULT_ADDR`.
If you need Nomad with a private CA again, set `NOMAD_CACERT` to that cluster's CA file instead of skipping verification.

**Other credential scan.**
A scan of the full history for credential-like names found only test fixtures, documentation mentions, and `HF_TOKEN_PATH`, which is a path, not a token.
The token file it points to has mode 600.

**PATH trust.**
No PATH directory is world-writable.
`/opt/homebrew/bin` is group-writable by `admin`, which is Homebrew's standard layout.
`~/Dropbox/bin` is a cloud-synced directory placed ahead of the Homebrew and system directories (R2).
Antigen's plugin clones are no longer on PATH (3.11).

**Command shadowing.**
Zsh's `stat` builtin no longer shadows `/usr/bin/stat` (3.9).
The global `gi` alias remains (R1).

**Unsafe evaluation.**
The remaining `eval` uses are the direnv hook, which is guarded by command presence, and the static color loop in `extra.zsh`.
Neither evaluates untrusted input.

## 6. Configuration quality

**Startup architecture.**
The sourcing order now reflects its real dependencies:
1. Cache setup.
2. Antigen.
3. PATH.
4. Completion styles, then completion (the single `compinit`).
5. Shell options and key bindings.
6. Optional tools (direnv, NVM, bun, gcloud).
7. Aliases, last.

Cache state lives in one private, persistent location that follows the XDG convention.

**Performance.**
Startup work is now dominated by Antigen's own loading, about 25 to 35 ms of shell-function time.
Inside repositories, the agnoster git prompt adds about 130 to 150 ms per prompt.
Neither was changed: Antigen is excluded from this work, and the prompt is a UX decision (R3).

**Maintainability.**
Duplicate and contradictory definitions were removed from `zstyles.zsh` and `variables.zsh`.
Where a surviving setting's purpose is not obvious, a comment explains why it exists.
Several inactive files remain by design (R22).
The shell options in `setopt.zsh` are the largest remaining source of surprising behavior (R4 to R6, R11).

**Portability.**
The active configuration no longer hardcodes home-directory paths, and the repository's location is derived at runtime.
Homebrew paths assume Apple Silicon (`/opt/homebrew`), which matches this machine.

**Reliability.**
Every optional tool (kubectl, kustomize, direnv, NVM, bun, autojump, gcloud) is guarded, so a missing tool means "not loaded" rather than an error.
Antigen itself is the exception (R18).
The Antigen hook removal and the kubectl cache generation both degrade safely if their assumptions stop holding.

## 7. Test results

All tests ran against the live configuration in freshly started shells.
They used a clean, launchd-like environment unless noted otherwise.

| Area | Test | Result |
| --- | --- | --- |
| Syntax | `zsh -n` on `zshrc` and every `*.zsh`; `bash -n` on `commands.sh` | Pass |
| Startup | Interactive login shell started from your home directory, an empty directory, a directory containing a file named `H`, and your inherited session environment; stderr must be empty | Pass (0 bytes in all four) |
| Startup | Antigen cache-rebuild startup after editing `zshrc` | Pass (no output) |
| Startup order | Non-login interactive shell with a minimal PATH still registers the direnv hook and kubectl completion | Pass |
| Non-interactive | `zsh -c` and `zsh -lc` PATH | Unchanged from before; these shells do not read `zshrc` (R7) |
| PATH | No literal `~`, no duplicates, no trailing slashes, every repository-managed directory exists, Dropbox ahead of Homebrew, Homebrew ahead of `/usr/bin` | Pass |
| PATH | No Antigen bundle directories on PATH; `update` does not resolve | Pass |
| PATH | Nested interactive shell keeps the same entry count | Pass |
| Resolution | `usvpn` (Dropbox), `brew`, `git`, `kubectl`, `direnv`, `bun`, `claude`, `nomad`, and `node` (still Homebrew's) | Pass |
| NVM | Loaded; `current` is `system`; the `default` and `node` aliases resolve; `nvm use 20` and `nvm use default` switch Node; `extendedglob` still on; no alias text in NVM's functions | Pass |
| Completion | Exactly one `compinit` (zprof); dump in `~/.cache/zsh`; directory mode 700; Antigen hook removed | Pass |
| Completion | Completers registered for `git`, `kubectl`, `brew`, `gh`, `bun`, `antigen`, and `ssh`; `_kubectl` autoloads | Pass |
| Completion (real TAB in a pseudo-terminal) | `git rebas`, `kubectl versio`, `k versio`, `brew instal`, `gh aut`, a case-insensitive path, and a dash-aware path | Pass (7 of 7) |
| Completion cache | A fresh `XDG_CACHE_HOME` creates a mode-700 cache; the kubectl cache regenerates when stale or empty and is untouched when fresh; a failing kubectl leaves no completer and no temporary file | Pass |
| Kustomize | Not installed; its completion is correctly not loaded | Pass (the registration path was not exercised, because `kustomize` is absent) |
| Styles | Effective cache path, two-stage matcher, no hosts override, no `COMMAND` header, `max-errors` value | Pass |
| Limits | An inherited soft limit of 10,240 is preserved; 256 is raised to 4,096 | Pass |
| History | `HISTFILE`, `HISTSIZE`, and `SAVEHIST` unchanged | Pass |
| Antigen | Bundle list identical to the original (15 lines: the Oh My Zsh library, 13 bundles, and the theme) | Pass |
| Aliases | `grp` uses `--keep` and `&&`; removed aliases are absent; core aliases and the global `gi` are present; your `grep` alias still overrides Oh My Zsh's; `ifactive` and `ips` produce output; `stat` is `/usr/bin/stat` | Pass |
| Key bindings (real pseudo-terminal) | Up-arrow substring search in both cursor-key modes; Home; End; Delete | Pass (4 of 4) |
| Direnv | Hook registered in `precmd` | Pass |
| Prompt | `PROMPT` expands without error; agnoster segments timed | Pass |
| Security | Legacy and credential variables absent from the environment | Pass |

**Test-harness failures encountered and resolved.**
Several first-run failures were caused by the tests themselves, not the configuration:
- A string-length check was used where an array-length check was needed.
- The global `gi` alias rewrote a test command, which is itself evidence for R1.
- `|` was treated as a pattern operator in a comparison.
- `noclobber` blocked test output redirection.
- The terminal driver did not drain output, so the shell under test blocked.

Each case was diagnosed and the test corrected; no configuration was changed to make a test pass.

**Not verified, and why.**
- `grp`, `afk`, `flush`, `show`, and `hide` were not executed, because they change repository, display, DNS, or Finder state.
- Kustomize completion registration was not exercised, because `kustomize` is not installed.
- The prompt's appearance in WezTerm (fonts, powerline glyphs, colors) was not inspected by eye. Prompt expansion was verified programmatically.
- `commands.sh` was not executed, as instructed. Its download and checksum were verified separately.

Interactive tests used isolated history files.
`~/.zhistory` was checked afterwards and contains no test commands.

## 8. Recommendations

**P0: Critical.**
- Rotate the historical OpsDB password if any system that accepts it still exists (section 5).

**P1: Important.**
- Review and commit this change set, so the credential and the TLS bypass are gone from the tip of the public repository.
- Restart WezTerm, so existing sessions stop inheriting the old PATH (R26).
- Decide on the global `gi` alias (R1).
- Revisit the Dropbox PATH position now that the risk is documented (R2).

**P2: Useful improvement.**
- Decide on `globdots`, `correctall`, and `extendedglob` versus git's `^` syntax, and tidy `setopt.zsh` (R4, R5, R6, R11).
- Set PATH for non-interactive shells through a repository-managed `~/.zprofile` (R7).
- Speed up the git segment of the prompt (R3).
- Reinstall gcloud at a stable path, or remove its lines (R17).

**P3: Optional.**
- Remove the dead color block in `extra.zsh` (R12).
- Review your alias overrides of Oh My Zsh's aliases, and the fragile aliases (R13, R20).
- Fix the Tab expansion comment, or enable `_expand` (R14).
- Align the color variables (R15).
- Guard a missing `~/antigen.zsh` (R18).
- Add `sudo` to `flush` (R19).
- Delete `~/.zcompdump` and quiet Antigen's debug log (R21).
- Decide which inactive files to keep (R22).
- Harden `commands.sh` (R24).
- Re-register the lost Oh My Zsh completions you use (R10).
- Use `exec zsh` instead of re-sourcing `~/.zshrc` (R8).

## 9. Git diff summary

Eleven tracked files are modified, and this report is the only new file.
`README.md` is modified, along with these files under `zsh/`:
- `aliases.zsh`
- `autojump.zsh`
- `commands.sh`
- `completion.zsh`
- `extra.zsh` (direnv guard only)
- `key_bindings.zsh`
- `modules.zsh`
- `variables.zsh`
- `zshrc`
- `zstyles.zsh`

The total is 187 insertions and 162 deletions.

These files are unchanged:
- `setopt.zsh`, `00-early.zsh`, `kustomize_completion.zsh`, `functions.zsh`, `hashed.zsh`, `custom_agnoster-theme.zsh`, and `plugins_configs.zsh`
- `wezterm.lua`
- everything under `claude/`, `global-claude/`, and `scripts/`

The working tree was clean before this work began.
The pre-existing stash `wip before rebase 1041` was not touched.
No commits, pushes, or PRs were made.

**Changes outside the repository, all generated and safe to delete.**
- `~/.cache/zsh/` was created. It holds the completion dump, the results cache, and the generated kubectl completion.
- Antigen regenerated `~/.antigen/init.zsh` and `~/.zshrc.zwc` automatically, because `zshrc` changed.

**Leftovers from the old setup.**
`~/.zcompdump` is no longer read and can be deleted by hand.
Antigen's `~/.antigen/.zcompdump` is still used during Antigen cache rebuilds and should be kept.

**Rollback.**
`git checkout -- zsh README.md` restores the previous configuration.
Then open a new shell; Antigen rebuilds its cache automatically.
`~/.cache/zsh` can be left in place or removed.

## 10. Final cleanup (safety fixes, autosuggestions, plugin review)

Date: 2026-10-13.
This section supersedes R1, R5, and R6 in section 4 and the `grp` description in 3.9.

### Safety changes

| Change | Validation |
| --- | --- |
| Removed the `grp` alias, with no replacement. | `alias grp` fails in a fresh shell. |
| Removed the global alias `gi`, with no replacement. | `galiases[gi]` is unset in a fresh shell. |
| Disabled `correctall` and kept `correct`. | `correctall` is off and `correct` is on. |
| Disabled `globdots` and kept `extendedglob`. | `*` in a directory containing `.hidden` and `vis` expands to `vis` only; `extendedglob` is still on. |

### zsh-autosuggestions

Added `zsh-users/zsh-autosuggestions` to the Antigen bundle list, just before `zsh-syntax-highlighting`, which is the order upstream expects so syntax highlighting can wrap the suggestion widgets.
Antigen cloned upstream `master` at `85919cd` (2025-06-24) on the first shell start.
The only setting is `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'` in `plugins_configs.zsh`, a muted gray that stays readable on Tokyo Night.
Everything else uses upstream defaults: history strategy, Right Arrow (`forward-char`) accepts, and history-substring-search widgets clear the suggestion.

Interactive test in a real pseudo-terminal, with an isolated history file: 14 of 14 checks passed.
- The suggestion appears in `fg=244`.
- Right Arrow accepts it, in both `^[[C` and `^[OC` modes.
- Left Arrow still only moves the cursor.
- Up and Down substring search still work, and the suggestion clears after Up.
- Syntax highlighting still marks unknown commands red and builtins green.
- TAB completion works.
- Home and Delete work.
- The agnoster prompt renders its segments.

Two first-run failures were test-harness artifacts, not defects.
In the first, the plugin's widget wrapper cleared the suggestion before the test's state-dump widget ran.
The fix was to add that widget to `ZSH_AUTOSUGGEST_IGNORE_WIDGETS`, which applies only to the test harness.
In the second, the test sent Right Arrow in the same write as the typed text, before the asynchronous suggestion arrived; the test now pauses the way a person would.

### Plugin review

| Bundle | Result | Reason |
| --- | --- | --- |
| `git` | Kept | Core git aliases and helpers. |
| `colored-man-pages` | Kept | Colors `man` output. |
| `colorize` | Removed | Nonfunctional here: `ccat` and `cless` need `pygmentize` or `chroma`, and neither is installed. |
| `cp` | Kept | `cpv` works with the system `rsync`. |
| `iterm2` | Kept | iTerm2 is still installed, and the plugin is inert outside iTerm2 because it is gated on `ITERM_SESSION_ID`. Its stray `update` script is already off PATH (3.11). |
| `screen` | Kept | GNU screen is installed, and the `reattach` function in `variables.zsh` uses it. |
| `systemadmin` | Kept | Some helpers work on macOS; there is no clear evidence it is obsolete. |
| `torrent` | Kept | Self-contained helpers; no evidence of breakage. |
| `zsh-navigation-tools` | Kept | Active: it binds Ctrl-R to its history widget. |
| `djui/alias-tips` | Kept | Active: it prints alias tips, and its `python3` dependency is present. |
| `zsh-users/zsh-completions` | Kept | Required. |
| `zsh-users/zsh-syntax-highlighting` | Kept | Required. |
| `zsh-users/zsh-history-substring-search` | Kept | Required. |
| `zsh-users/zsh-autosuggestions` | Added | Requested. |

Plugin updates: none.
Every existing clone has a clean working tree.
The only untracked files are the compatibility shims Antigen generates in the Oh My Zsh clone, and no plugin showed a defect that an update would fix.

### Startup

Same methodology as section 2: clean environment, 15 runs, warm-up excluded, median with range.

| Measurement | Before this section | After |
| --- | --- | --- |
| `zsh -lic exit` | 120 ms (117 to 127) | 120 ms (115 to 128) |
| Time until the line editor is ready, inside this repository | 288 ms (279 to 304) | 286 ms (273 to 339) |

The 120 ms baseline taken today is within run-to-run variance of the 112 ms in section 2, and autosuggestions added no measurable cost.

### Regression results

The runtime suite passed 64 of 64 checks, the audit-regression suite 11 of 11, and the earlier interactive suite 12 of 12.
The robustness checks (silent startup in four environments, stable PATH, kubectl cache behavior) all passed, and `zsh -n` passes on every file.
No regressions and no unresolved issues requiring attention.
