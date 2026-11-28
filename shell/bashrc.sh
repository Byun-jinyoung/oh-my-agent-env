# shellcheck shell=bash
# Shared bash settings, sourced from a marker block in ~/.bashrc and ~/.bash_profile
# by `setup.sh sync`. Machine-specific lines (conda init, ssh hosts, app paths,
# secrets) stay in those files outside the block. Every alias here is added only
# when the machine has not already defined it, so local definitions always win.

[ -n "${_OH_MY_ENV_SHELL:-}" ] && return 0   # not exported: once per shell
_OH_MY_ENV_SHELL=1

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
if [ -d "$HOME/.bun/bin" ]; then
  export BUN_INSTALL="$HOME/.bun"
  case ":$PATH:" in *":$BUN_INSTALL/bin:"*) ;; *) export PATH="$BUN_INSTALL/bin:$PATH" ;; esac
fi
# nvm only as a fallback: a node from mise, conda or the system keeps priority.
if ! command -v node >/dev/null 2>&1 && [ -s "$HOME/.nvm/nvm.sh" ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
fi
# Headless Linux has no unlockable Secret Service; agy otherwise waits up to 5s on it before using its token file.
[ "$(uname -s)" = Linux ] && export AGY_CLI_FORCE_FILE_TOKEN_STORAGE=1

case $- in *i*) ;; *) return 0 ;; esac   # the rest is for interactive shells

_ome_alias() { alias "$1" >/dev/null 2>&1 || alias "$1=$2"; }

# navigation
_ome_alias cdp 'cd ..'
_ome_alias cdtw 'cd ../..'
_ome_alias cdtr 'cd ../../..'
_ome_alias cdfo 'cd ../../../..'
_ome_alias cdff 'cd ../../../../..'
# files and editing
_ome_alias e 'emacs -nw'
_ome_alias rm 'rm -i'
_ome_alias rmf 'rm -f'
_ome_alias cls 'clear'
_ome_alias lao 'ls -althr'
_ome_alias clao 'clear && ls -althr'
_ome_alias tlf 'tail -f'
_ome_alias hisgp 'history | grep'
_ome_alias br 'e ~/.bashrc'
_ome_alias sbr 'source ~/.bashrc'
_ome_alias bp 'e ~/.bash_profile'
_ome_alias sbp 'source ~/.bash_profile'
# tools
_ome_alias py3 'python3'
_ome_alias nhb 'nohup bash'
_ome_alias gp 'gnuplot'
_ome_alias ccr 'claude --resume'
command -v nvidia-smi >/dev/null 2>&1 && _ome_alias gpu_usage 'watch -d -n 1.0 nvidia-smi'
if command -v sbatch >/dev/null 2>&1; then
  _ome_alias sba 'sbatch'
  _ome_alias scc 'scancel'
  _ome_alias sbdep 'sbatch --dependency=afterok'
  _ome_alias sqme 'squeue -u "$USER" -o "%.13i %.13P %.60j %.8T %.10M %.4D %R %Q "'
  _ome_alias sqgpu 'sqme | grep gpu'
  _ome_alias sqcpu 'sqme | grep cpu'
fi
if type module >/dev/null 2>&1; then
  _ome_alias modav 'module av'
  _ome_alias modld 'module load'
  _ome_alias modls 'module list'
  _ome_alias modpg 'module purge'
fi

case "$(uname -s)" in
  Darwin)
    export CLICOLOR=1
    export LSCOLORS=ExFxCxGxBxegedabagaced
    ;;
  Linux)
    _ome_alias ls 'ls --color=auto'
    _ome_alias ll 'ls -alF'
    _ome_alias la 'ls -A'
    ;;
esac

unset -f _ome_alias
