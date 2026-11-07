
reality_pbk() { # $1 = ТЕКСТ streamSettings (уже объект для jq)
  jq -r '.realitySettings.settings.publicKey // .realitySettings.publicKey // ""' <<<"$1" 2>/dev/null
}
reality_sid() { jq -r '.realitySettings.shortIds[0] // ""' <<<"$1" 2>/dev/null; }
reality_sni() { jq -r '.realitySettings.serverNames[0] // ""' <<<"$1" 2>/dev/null; }

# собирает одну ссылку для клиента
link_for_client() { # $1 inbound JSON, $2 client JSON (settings-объект)
  local ib="$1" cl="$2"
  local id port proto tag2 mode rnet rpath
  id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
  proto="$(jq -r '.protocol' <<<"$ib")"
  IFS='|' read -r mode rnet rpath <<<"$(route_info "$id")"

  local stream="" host="" path="" svc="" sni="" pbk="" sid="" flow="" email="" uuid="" pass="" method=""
  stream="$(jq -r '.streamSettings // "{}"' <<<"$ib")"
  host="${XKIT_HOST}"
  email="$(jq -r '.email // "user"' <<<"$cl")"
  flow="$(jq -r '.flow // ""' <<<"$cl")"

  if [ "$mode" = "local" ]; then
    # за nginx: TLS на 443, путь из routes.tsv
    case "$rnet" in
      grpc) svc="$(inbound_path "$ib" grpc)"; [ -n "$svc" ] || svc="xk-gr-${port}" ;;
      ws|xhttp|httpupgrade) path="$(inbound_path "$ib" "$rnet")"; [ -n "$path" ] || path="$rpath" ;;
      tcp) path="$(inbound_path "$ib" tcp)"; [ -n "$path" ] || path="$rpath" ;;
    esac
    _link_proto "$proto" "$email" "$host" 443 "$rnet" "tls" "$path" "$svc" "$host" "" "" "" "$flow" "$cl" "$ib"
  else
    # direct: реальный порт, security из streamSettings ($stream — уже JSON-текст)
    local net="" sec=""
    net="$(jq -r '.network // "tcp"' <<<"$stream" 2>/dev/null)"
    sec="$(jq -r '.security // "none"' <<<"$stream" 2>/dev/null)"
    [ "$sec" = "tls" ] && sni="$host"
    if [ "$sec" = "reality" ]; then
      pbk="$(reality_pbk "$stream")"; sid="$(reality_sid "$stream")"; sni="$(reality_sni "$stream")"
      [ -n "$sni" ] || sni="$host"
    fi
    # v5.2: direct XHTTP/WS/gRPC тоже нуждаются в path/serviceName; раньше
    # direct-ветка всегда передавала пустые значения, и XHTTP-ссылка была неполной.
    case "$net" in
      ws|xhttp|splithttp|httpupgrade) path="$(inbound_path "$ib" "$net")" ;;
      grpc) svc="$(inbound_path "$ib" grpc)" ;;
      tcp) path="$(inbound_path "$ib" tcp)" ;;
    esac
    _link_proto "$proto" "$email" "$host" "$port" "$net" "$sec" "$path" "$svc" "${sni:-}" "$pbk" "$sid" "" "$flow" "$cl" "$ib"
  fi
}

# внутренний сборщик ссылки по протоколу
_link_proto() { # proto email host port net sec path svc sni pbk sid fp flow client ib
  local proto="$1" email="$2" host="$3" port="$4" net="$5" sec="$6" path="${7:-}" svc="${8:-}"
  local sni="${9:-}" pbk="${10:-}" sid="${11:-}" fp="${12:-}" flow="${13:-}" cl="${14}" ib="${15}"
  local q="" e; e="$(enc_uri "$email")"
  local link=""

  case "$proto" in
    vless)
      local uuid; uuid="$(jq -r '.id // ""' <<<"$cl")"
      [ -n "$uuid" ] || return 0
      q="type=${net}&security=${sec}"
      case "$net" in
        ws)          q+="&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
        grpc)        q+="&serviceName=$(enc_uri "$svc")&mode=gun" ;;
        xhttp|splithttp) q+="&path=$(enc_uri_path "$path")&mode=auto" ;;
        httpupgrade) q+="&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
        tcp)         [ -n "$path" ] && q+="&headerType=http&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
      esac
      if [ "$sec" = "tls" ]; then
        q+="&sni=$(enc_uri "${sni:-$host}")&fp=${fp:-chrome}"
      elif [ "$sec" = "reality" ]; then
        q+="&sni=$(enc_uri "$sni")&fp=${fp:-chrome}&pbk=$(enc_uri "$pbk")"
        [ -n "$sid" ] && q+="&sid=$(enc_uri "$sid")"
        [ -n "$flow" ] && q+="&flow=$(enc_uri "$flow")"
      fi
      link="vless://${uuid}@${host}:${port}?${q}#${e}" ;;

    vmess)
      local uuid tls
      uuid="$(jq -r '.id // ""' <<<"$cl")"; [ -n "$uuid" ] || return 0
      [ "$sec" = "tls" ] && tls="tls" || tls=""
      [ "$net" = "xhttp" ] && net="xhttp"
      local cj
      cj="$(jq -nc --arg ps "$email" --arg add "$host" --arg port "$port" --arg id "$uuid" \
        --arg net "$net" --arg host "$host" --arg path "$path" --arg tls "$tls" --arg sni "${sni:-$host}" \
        --arg svc "$svc" --arg sec "$sec" '
        {v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:"none",
         host:$host,path:(if $net=="grpc" then $svc else $path end),
         tls:$tls,sni:(if $tls=="tls" then $sni else "" end),
         sn:(if $net=="grpc" then $svc else "" end)}')"
      link="vmess://$(printf '%s' "$cj" | base64 -w0)" ;;

    trojan)
      pass="$(jq -r '.password // .id // ""' <<<"$cl")"; [ -n "$pass" ] || return 0
      q="security=${sec}&type=${net}&sni=$(enc_uri "${sni:-$host}")"
      case "$net" in
        ws)   q+="&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
        grpc) q+="&serviceName=$(enc_uri "$svc")&mode=gun" ;;
        xhttp|splithttp) q+="&path=$(enc_uri_path "$path")&mode=auto" ;;
      esac
      link="trojan://$(enc_uri "$pass")@${host}:${port}?${q}#${e}" ;;

    shadowsocks)
      # ss живёт прямым портом; клиент ss в 3x-ui: password в клиенте или в settings
      pass="$(jq -r '.password // ""' <<<"$cl")"
      [ -n "$pass" ] || pass="$(jq -r '.settings|fromjson?|.password // ""' <<<"$ib")"
      [ -n "$pass" ] || return 0
      method="$(jq -r '.settings|fromjson?|.method // "aes-256-gcm"' <<<"$ib")"
      link="ss://$(printf '%s' "${method}:${pass}" | base64 -w0)@${host}:${port}#${e}" ;;

    *) return 0 ;;
  esac
  printf '%s\n' "$link"
}
