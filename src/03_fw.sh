
#=========================== FIREWALL: ТОЛЬКО ПРАВИЛА XKIT ======================
xkit_ufw_active() {
  local st
  command -v ufw >/dev/null 2>&1 || return 1
  st="$(ufw status 2>/dev/null)" || return 1
  grep -q '^Status: active' <<<"$st"
}

xkit_fw_rule_line() { # $1 port, $2 proto, $3 owner
  [[ "$1" =~ ^[0-9]+$ ]] && is_port "$1" || return 1
  [[ "$2" =~ ^(tcp|udp)$ && "$3" =~ ^[a-z0-9-]+$ ]] || return 1
  ufw status 2>/dev/null | grep -E "^${1}/${2}[[:space:]]+ALLOW[[:space:]].*XKIT:${3}([[:space:]]|$)"
}

xkit_fw_add() { # $1 owner, $2 port, $3 tcp|udp; чужой allow не трогаем
  local owner="$1" port="$2" proto="$3"
  [[ "$owner" =~ ^[a-z0-9-]+$ && "$proto" =~ ^(tcp|udp)$ ]] || return 1
  is_port "$port" || return 1
  xkit_ufw_active || return 0
  xkit_fw_rule_line "$port" "$proto" "$owner" >/dev/null && return 0
  # Уже существующее общее разрешение считаем внешним: повторять/удалять его не надо.
  if ufw status 2>/dev/null | grep -E "^${port}/${proto}[[:space:]]+ALLOW[[:space:]]" >/dev/null; then
    return 0
  fi
  ufw allow "${port}/${proto}" comment "XKIT:${owner}" >/dev/null || return 1
  xkit_fw_rule_line "$port" "$proto" "$owner" >/dev/null
}

xkit_fw_remove() { # $1 owner, $2 port, $3 tcp|udp; без метки XKIT — не удаляем
  local owner="$1" port="$2" proto="$3"
  [[ "$owner" =~ ^[a-z0-9-]+$ && "$proto" =~ ^(tcp|udp)$ ]] || return 1
  is_port "$port" || return 1
  xkit_ufw_active || return 0
  xkit_fw_rule_line "$port" "$proto" "$owner" >/dev/null || return 0
  ufw delete allow "${port}/${proto}" comment "XKIT:${owner}" >/dev/null || return 1
  ! xkit_fw_rule_line "$port" "$proto" "$owner" >/dev/null
}

xkit_awg_route_add() { # $1 внешний интерфейс
  local dev="$1"
  [[ "$dev" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  xkit_ufw_active || return 0
  if ufw status 2>/dev/null | grep -F 'XKIT:awg-forward' >/dev/null; then
    # (баг №4, аудит v5.2.1): сверяем пару awg0 -> $dev, а не «любое XKIT-правило»;
    # при смене внешнего интерфейса (eth0 -> eth1) старая пара снимается, иначе
    # новый интерфейс навсегда остаётся закрытым
    if ufw status 2>/dev/null | grep -F 'XKIT:awg-forward' | grep -F -- "on $dev" | grep -F 'awg0' >/dev/null; then
      return 0
    fi
    local od
    od="$(ufw status 2>/dev/null | grep -F 'XKIT:awg-forward' | sed -n 's/.*out on \([^ ]*\).*/\1/p' | head -n1)"
    [ -n "$od" ] && xkit_awg_route_remove "$od" >/dev/null 2>&1 || true
  fi
  ufw route allow in on awg0 out on "$dev" comment 'XKIT:awg-forward' >/dev/null || return 1
  ufw route allow in on "$dev" out on awg0 comment 'XKIT:awg-forward' >/dev/null || {
    ufw delete route allow in on awg0 out on "$dev" comment 'XKIT:awg-forward' >/dev/null 2>&1 || true
    return 1
  }
}

xkit_awg_route_remove() { # $1 сохранённый внешний интерфейс
  local dev="$1"
  [[ "$dev" =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
  xkit_ufw_active || return 0
  if ufw status 2>/dev/null | grep -F 'XKIT:awg-forward' >/dev/null; then
    ufw delete route allow in on awg0 out on "$dev" comment 'XKIT:awg-forward' >/dev/null 2>&1 || true
    ufw delete route allow in on "$dev" out on awg0 comment 'XKIT:awg-forward' >/dev/null 2>&1 || true
  fi
}
