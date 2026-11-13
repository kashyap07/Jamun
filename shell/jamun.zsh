# jamun zsh integration.
# Source this from ~/.zshrc. It tells the jamun host what you are typing and
# applies the completions you pick. It does nothing if the host is not running.

[[ -o interactive && -t 0 && -z ${JAMUN_DISABLE:-} ]] || return 0
(( ${+_JAMUN_LOADED} )) && return 0
zmodload zsh/net/socket 2>/dev/null || return 0
typeset -g _JAMUN_LOADED=1

autoload -Uz add-zsh-hook add-zle-hook-widget

typeset -g _JAMUN_SOCK=${JAMUN_SOCKET:-$HOME/.jamun/jamun.sock}
typeset -g _JAMUN_FD=
typeset -g _JAMUN_SID="$$-$RANDOM$RANDOM"
typeset -g _JAMUN_LAST=
typeset -gA _JAMUN_ORIG   # key sequence -> widget it was bound to
typeset -ga _JAMUN_BOUND  # key sequences currently taken over by the popup

# key name -> escape sequences that produce it
typeset -gA _JAMUN_SEQS
_JAMUN_SEQS=(
  up          $'\e[A \eOA'
  down        $'\e[B \eOB'
  tab         $'\t'
  shift+tab   $'\e[Z'
  enter       $'\r'
  esc         $'\e'
  control+p   $'\x10'
  control+n   $'\x0e'
)

# JSON-escape $1 into REPLY.
_jamun_json() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\e'/\\u001b}
  REPLY=${s//[[:cntrl:]]/}
}

_jamun_disconnect() {
  [[ -n $_JAMUN_FD ]] || return 0
  zle -F $_JAMUN_FD 2>/dev/null
  exec {_JAMUN_FD}>&- 2>/dev/null
  _JAMUN_FD=
  _JAMUN_LAST=
  _jamun_set_keys
}

_jamun_send() {
  [[ -n $_JAMUN_FD ]] || return 1
  print -r -u $_JAMUN_FD -- "$1" 2>/dev/null || { _jamun_disconnect; return 1 }
}

_jamun_connect() {
  [[ -n $_JAMUN_FD ]] && return 0
  [[ -S $_JAMUN_SOCK ]] || return 1
  zsocket $_JAMUN_SOCK 2>/dev/null || return 1
  _JAMUN_FD=$REPLY
  zle -F -w $_JAMUN_FD _jamun-recv
  _jamun_json "${TTY:-}"; local tty=$REPLY
  _jamun_json "${SHELL:-/bin/zsh}"; local shell=$REPLY
  _jamun_send "{\"t\":\"hello\",\"sid\":\"$_JAMUN_SID\",\"pid\":$$,\"tty\":\"$tty\",\"shell\":\"$shell\"}"
}

# Runs before each prompt: (re)connect and report where we are.
_jamun_precmd() {
  local exit_code=$?
  _jamun_connect || return 0
  _jamun_json "$PWD"; local cwd=$REPLY
  _jamun_json "$PATH"; local path_value=$REPLY
  _jamun_send "{\"t\":\"prompt\",\"cwd\":\"$cwd\",\"path\":\"$path_value\",\"exit\":$exit_code}"
}

# Report the edit buffer whenever it changes.
_jamun_report() {
  [[ -n $_JAMUN_FD ]] || return 0
  local signature="$CURSOR:$BUFFER"
  [[ $signature == $_JAMUN_LAST ]] && return 0
  _JAMUN_LAST=$signature
  _jamun_json "$BUFFER"; local buf=$REPLY
  _jamun_json "$PWD"; local cwd=$REPLY
  _jamun_send "{\"t\":\"edit\",\"buf\":\"$buf\",\"cur\":$CURSOR,\"cwd\":\"$cwd\"}"
}

_jamun_line_init() {
  _JAMUN_LAST=
  _jamun_set_keys
  _jamun_report
}

_jamun_line_finish() {
  _jamun_set_keys
  _jamun_send '{"t":"finish"}'
}

# While the popup is open, its keys are rebound in the main keymap and the
# previous bindings are put back as soon as it closes. (A separate keymap
# selected with `zle -K` would be simpler, but switching keymaps from a
# `zle -F` handler segfaults zsh 5.9.)
_jamun_set_keys() {
  local seq key out
  for seq in $_JAMUN_BOUND; do
    if [[ ${_JAMUN_ORIG[$seq]} == undefined-key ]]; then
      bindkey -M main -r -- "$seq" 2>/dev/null
    else
      bindkey -M main -- "$seq" "${_JAMUN_ORIG[$seq]}"
    fi
  done
  _JAMUN_BOUND=()
  for key in "$@"; do
    (( ${+_JAMUN_SEQS[$key]} )) || continue
    for seq in ${=_JAMUN_SEQS[$key]}; do
      if (( ! ${+_JAMUN_ORIG[$seq]} )); then
        # Looked up once per shell: this is the only fork in the integration.
        out=$(bindkey -M main -- "$seq")
        _JAMUN_ORIG[$seq]=${out##* }
      fi
      bindkey -M main -- "$seq" "_jamun-key-$key"
      _JAMUN_BOUND+=("$seq")
    done
  done
}

# Forward a captured key to the popup, then wait for its answer and apply it
# here. Doing it inside the key's own widget matters: zsh ignores accept-line
# when it is called from the socket callback, so "run this now" would only
# happen on the next keypress.
_jamun_key() {
  if ! _jamun_send "{\"t\":\"key\",\"key\":\"${WIDGET#_jamun-key-}\"}"; then
    # Host went away: _jamun_send restored the normal bindings, so replay the key.
    zle -U "$KEYS"
    return 0
  fi
  local line
  while IFS= read -r -t 0.3 -u $_JAMUN_FD line; do
    [[ $line == done ]] && break
    _jamun_dispatch "$line"
  done
}

# Apply an edit chosen in the popup.
_jamun_insert() {
  local -i deletion=$1 move_left=$2 immediate=$3
  local text=${(g::)4}
  if (( deletion > 0 )); then
    if (( deletion >= ${#LBUFFER} )); then
      LBUFFER=
    else
      LBUFFER=${LBUFFER[1,-deletion-1]}
    fi
  fi
  LBUFFER+=$text
  (( move_left > 0 )) && (( CURSOR = CURSOR > move_left ? CURSOR - move_left : 0 ))
  if (( immediate )); then
    _jamun_set_keys
    zle accept-line
  else
    zle -R
    _jamun_report
  fi
}

# Act on one line from the host. Fields are tab separated.
_jamun_dispatch() {
  local -a fields
  fields=("${(@ps:\t:)1}")
  case $fields[1] in
    keys)   _jamun_set_keys ${(s:,:)fields[2]} ;;
    insert) _jamun_insert "$fields[2]" "$fields[3]" "$fields[4]" "$fields[5]" ;;
  esac
}

# Socket callback: the host sent something while zsh was waiting for a key.
_jamun_recv() {
  local fd=$1 line
  if [[ -n ${2:-} ]] || ! IFS= read -r -u $fd line; then
    _jamun_disconnect
    return 0
  fi
  _jamun_dispatch "$line"
}

zle -N _jamun-recv _jamun_recv
() {
  local key
  for key in ${(k)_JAMUN_SEQS}; do
    zle -N "_jamun-key-$key" _jamun_key
  done
}

add-zsh-hook precmd _jamun_precmd
add-zle-hook-widget line-init _jamun_line_init
add-zle-hook-widget line-pre-redraw _jamun_report
add-zle-hook-widget line-finish _jamun_line_finish
