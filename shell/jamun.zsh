# Jamun protocol v2. Source from ~/.zshrc; no host means ordinary zsh behavior.
[[ -o interactive && -t 0 && -z ${JAMUN_DISABLE:-} ]] || return 0
(( ${+_JAMUN_LOADED} )) && return 0
zmodload zsh/net/socket 2>/dev/null || return 0
zmodload zsh/datetime 2>/dev/null || return 0
typeset -g _JAMUN_LOADED=1
autoload -Uz add-zsh-hook add-zle-hook-widget
typeset -g _JAMUN_SOCK=${JAMUN_SOCKET:-$HOME/.jamun/jamun.sock}
typeset -g _JAMUN_FD= _JAMUN_LAST= _JAMUN_KEY_ID=0 _JAMUN_KEYTIMEOUT= _JAMUN_KEYTIMEOUT_SET=
typeset -g _JAMUN_SID="$$-$RANDOM$RANDOM"
typeset -gi _JAMUN_REVISION=0 _JAMUN_KEY_COUNTER=0 _JAMUN_KEY_APPLIED=0 _JAMUN_KEY_REJECTED=0 _JAMUN_READY=0
typeset -gA _JAMUN_ORIG _JAMUN_SEQS
typeset -ga _JAMUN_BOUND
# Explicit separators preserve whitespace key sequences, especially Tab.
_JAMUN_SEQS=(
  up $'\e[A|\eOA' down $'\e[B|\eOB' tab $'\t' shift+tab $'\e[Z'
  enter $'\r' esc $'\e' control+p $'\x10' control+n $'\x0e'
  control+k $'\x0b' control+r $'\x12'
)
_jamun_json() {
  emulate -L zsh
  local s=$1 ch escaped
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  # Escape controls rather than removing them and invalidating cursor positions.
  if [[ $s == *[[:cntrl:]]* ]]; then
    local out= char
    for char in ${(s::)s}; do
      if [[ $char == [[:cntrl:]] ]]; then
        printf -v escaped '\\u%04x' "'$char"
        out+=$escaped
      else
        out+=$char
      fi
    done
    s=$out
  fi
  REPLY=$s
}
_jamun_set_keys() {
  emulate -L zsh
  local seq key out
  local -A desired
  local -a next_bound
  for key in "$@"; do
    (( ${+_JAMUN_SEQS[$key]} )) || continue
    for seq in "${(@s:|:)_JAMUN_SEQS[$key]}"; do
      desired[$seq]="_jamun-key-$key"
      next_bound+=("$seq")
    done
  done
  # Keep unchanged bindings installed. Repeated suggestion updates must not
  # fork once per key or create a gap in which arrows reach shell history.
  for seq in "${_JAMUN_BOUND[@]}"; do
    (( ${+desired[$seq]} )) && continue
    if [[ ${_JAMUN_ORIG[$seq]} == undefined-key ]]; then
      bindkey -M main -r -- "$seq" 2>/dev/null
    else
      bindkey -M main -- "$seq" "${_JAMUN_ORIG[$seq]}"
    fi
    unset "_JAMUN_ORIG[$seq]"
  done
  for seq in "${next_bound[@]}"; do
    (( ${+_JAMUN_ORIG[$seq]} )) && continue
    out=$(bindkey -M main -- "$seq")
    _JAMUN_ORIG[$seq]=${out##* }
    bindkey -M main -- "$seq" "$desired[$seq]"
  done
  _JAMUN_BOUND=("${next_bound[@]}")
}
# A bare Esc is a prefix of arrow and Alt sequences, so zsh holds it for
# KEYTIMEOUT (400ms by default) before running any widget. zsh reads the value
# once per line, so it is lowered before each prompt and restored afterwards.
# The default is 1 (10ms), the smallest wait zsh supports.
# JAMUN_KEYTIMEOUT overrides the value in hundredths of a second; 0 disables.
_jamun_keytimeout() {
  emulate -L zsh
  if [[ $1 == lower ]]; then
    local want=${JAMUN_KEYTIMEOUT:-1}
    [[ -z $_JAMUN_KEYTIMEOUT && $want == <1-> ]] && (( ${KEYTIMEOUT:-40} > want )) || return 0
    _JAMUN_KEYTIMEOUT=${KEYTIMEOUT:-40} _JAMUN_KEYTIMEOUT_SET=$want
    KEYTIMEOUT=$want
  elif [[ -n $_JAMUN_KEYTIMEOUT ]]; then
    # Leave it alone if something else changed it in the meantime.
    [[ $KEYTIMEOUT == $_JAMUN_KEYTIMEOUT_SET ]] && KEYTIMEOUT=$_JAMUN_KEYTIMEOUT
    _JAMUN_KEYTIMEOUT=
  fi
}
_jamun_disconnect() {
  emulate -L zsh
  if [[ -n $_JAMUN_FD ]]; then
    zle -F $_JAMUN_FD 2>/dev/null
    exec {_JAMUN_FD}>&- 2>/dev/null
  fi
  _JAMUN_FD=; _JAMUN_LAST=; _JAMUN_KEY_ID=0; _JAMUN_READY=0
  _jamun_set_keys
  _jamun_keytimeout restore
}
_jamun_send() {
  emulate -L zsh
  [[ -n $_JAMUN_FD ]] || return 1
  print -r -u $_JAMUN_FD -- "$1" 2>/dev/null || { _jamun_disconnect; return 1; }
}
_jamun_connect() {
  emulate -L zsh
  [[ -n $_JAMUN_FD ]] && return 0
  [[ -S $_JAMUN_SOCK ]] || return 1
  zsocket $_JAMUN_SOCK 2>/dev/null || return 1
  _JAMUN_FD=$REPLY
  zle -F -w $_JAMUN_FD _jamun-recv
  _jamun_json "${TTY:-}"; local tty=$REPLY
  _jamun_json "${SHELL:-/bin/zsh}"; local shell=$REPLY
  _jamun_send "{\"t\":\"hello\",\"version\":2,\"sid\":\"$_JAMUN_SID\",\"pid\":$$,\"tty\":\"$tty\",\"shell\":\"$shell\"}"
}
_jamun_precmd() {
  emulate -L zsh
  _jamun_connect || return 0
  _jamun_keytimeout lower
  _jamun_json "$PWD"; local cwd=$REPLY
  local env_json= alias_json= name key value
  # Context only: never serialize the entire environment or credential values.
  for name in PATH HOME USER LANG LC_ALL LC_CTYPE KUBECONFIG AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION GOOGLE_CLOUD_PROJECT CLOUDSDK_CORE_PROJECT VIRTUAL_ENV CONDA_PREFIX PYENV_VERSION NVM_BIN GOPATH CARGO_HOME XDG_CONFIG_HOME SSH_AUTH_SOCK; do
    (( ${+parameters[$name]} )) || continue
    _jamun_json "${(P)name}"; value=$REPLY
    env_json+="${env_json:+,}\"$name\":\"$value\""
  done
  for name in ${(k)aliases}; do
    _jamun_json "$name"; key=$REPLY
    _jamun_json "$aliases[$name]"; value=$REPLY
    alias_json+="${alias_json:+,}\"$key\":\"$value\""
    (( ${#alias_json} > 65536 )) && { alias_json=; break; }
  done
  _jamun_send "{\"t\":\"prompt\",\"cwd\":\"$cwd\",\"environment\":{$env_json},\"aliases\":{$alias_json}}"
}
_jamun_report() {
  emulate -L zsh
  [[ -n $_JAMUN_FD ]] || return 0
  # Very large pasted commands should not block the interactive editor.
  (( ${#BUFFER} > 32768 )) && { _jamun_disconnect; return 0; }
  local signature="$CURSOR:$BUFFER"
  [[ $signature == $_JAMUN_LAST ]] && return 0
  _JAMUN_LAST=$signature
  (( ++_JAMUN_REVISION ))
  _jamun_json "$BUFFER"; local buf=$REPLY
  _jamun_json "$PWD"; local cwd=$REPLY
  _jamun_send "{\"t\":\"edit\",\"buf\":\"$buf\",\"cur\":$CURSOR,\"rev\":$_JAMUN_REVISION,\"cwd\":\"$cwd\"}"
}
_jamun_line_init() { _JAMUN_LAST=; _jamun_set_keys; _jamun_report; }
_jamun_line_finish() {
  emulate -L zsh
  _jamun_set_keys
  _jamun_keytimeout restore
  (( ++_JAMUN_REVISION ))
  _jamun_send "{\"t\":\"finish\",\"rev\":$_JAMUN_REVISION}"
}
_jamun_key() {
  emulate -L zsh
  local replay=$KEYS line done_id handled
  local original_widget=${_JAMUN_ORIG[$KEYS]:-undefined-key}
  _jamun_report
  (( ++_JAMUN_KEY_COUNTER ))
  _JAMUN_KEY_ID=$_JAMUN_KEY_COUNTER
  _JAMUN_KEY_APPLIED=0
  _JAMUN_KEY_REJECTED=0
  if _jamun_send "{\"t\":\"key\",\"key\":\"${WIDGET#_jamun-key-}\",\"keyId\":\"$_JAMUN_KEY_ID\",\"rev\":$_JAMUN_REVISION}"; then
    local -F deadline=$(( EPOCHREALTIME + 0.3 )) remaining
    while (( (remaining = deadline - EPOCHREALTIME) > 0 )) && IFS= read -r -t $remaining -u $_JAMUN_FD line; do
      if [[ $line == done$'\t'* ]]; then
        local -a fields=("${(@ps:\t:)line}")
        [[ $fields[2] == $_JAMUN_KEY_ID ]] || continue
        handled=$fields[3]
        _JAMUN_KEY_ID=0
        if [[ ( $handled != 1 || $_JAMUN_KEY_REJECTED == 1 ) && $_JAMUN_KEY_APPLIED == 0 ]]; then
          # Pass through this key only; keep navigation available for the
          # next event. Replaying with live interception would recurse.
          zle "$original_widget"
        fi
        return 0
      fi
      _jamun_dispatch "$line"
    done
  fi
  # Closing the connection invalidates late responses before replaying a key.
  _jamun_disconnect
  (( _JAMUN_KEY_APPLIED )) || zle -U "$replay"
}
_jamun_insert() {
  emulate -L zsh
  # request, key transaction, revision, cursor, expiry(ms), deletion, move, execute, buffer, text
  local request_id=$1 key_id=$2 expected_rev=$3 expected_cursor=$4 expires=$5
  local -i deletion=$6 move_left=$7 immediate=$8
  local buffer_field=$9 text_field=${10}
  local expected_buffer=${(g::)${buffer_field#v}} text=${(g::)${text_field#v}}
  local accepted=false
  if [[ $expected_rev == $_JAMUN_REVISION && $expected_cursor == $CURSOR && $expected_buffer == $BUFFER ]] &&
     [[ $key_id == 0 || $key_id == $_JAMUN_KEY_ID ]] &&
     (( EPOCHREALTIME * 1000 <= expires && deletion >= 0 && deletion <= ${#LBUFFER} && move_left >= 0 && move_left <= ${#LBUFFER} - deletion + ${#text} )); then
    if (( deletion == ${#LBUFFER} )); then LBUFFER=
    elif (( deletion > 0 )); then LBUFFER=${LBUFFER[1,-deletion-1]}; fi
    LBUFFER+=$text
    (( move_left > 0 )) && (( CURSOR -= move_left ))
    accepted=true
    [[ $key_id != 0 ]] && _JAMUN_KEY_APPLIED=1
  fi
  _jamun_send "{\"t\":\"editAck\",\"requestId\":\"$request_id\",\"accepted\":$accepted}"
  if [[ $accepted != true ]]; then
    [[ $key_id == $_JAMUN_KEY_ID && $key_id != 0 ]] && _JAMUN_KEY_REJECTED=1
    return 0
  fi
  if (( immediate )); then
    _jamun_set_keys
    if [[ $key_id == 0 ]]; then zle -U $'\r'; else zle accept-line; fi
  else
    zle -R
    _jamun_report
  fi
}
_jamun_dispatch() {
  emulate -L zsh
  local -a fields=("${(@ps:\t:)1}")
  case $fields[1] in
    hello)
      if [[ $fields[2] == 2 ]]; then _JAMUN_READY=1; else _jamun_disconnect; fi ;;
    keys)
      # A legacy host cannot acknowledge v2 key transactions. Never capture
      # input until it has explicitly confirmed the same protocol version.
      if (( _JAMUN_READY )); then _jamun_set_keys ${(s:,:)fields[2]}; else _jamun_disconnect; fi ;;
    insert) (( ${#fields} == 11 )) && _jamun_insert "${fields[@]:1}" ;;
    resync) _JAMUN_LAST=; _jamun_report ;;
  esac
}
_jamun_recv() {
  emulate -L zsh
  local fd=$1 line
  # A partial/malformed frame must never leave the editor blocked indefinitely.
  if [[ -n ${2:-} ]] || ! IFS= read -r -t 0.05 -u $fd line; then _jamun_disconnect; return 0; fi
  _jamun_dispatch "$line"
}
zle -N _jamun-recv _jamun_recv
() { local key; for key in ${(k)_JAMUN_SEQS}; do zle -N "_jamun-key-$key" _jamun_key; done; }
add-zsh-hook precmd _jamun_precmd
add-zle-hook-widget line-init _jamun_line_init
add-zle-hook-widget line-pre-redraw _jamun_report
add-zle-hook-widget line-finish _jamun_line_finish
