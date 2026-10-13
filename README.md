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
