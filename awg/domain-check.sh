#!/bin/bash
# awg-domain-check: куда пойдёт домен и открывается ли он через туннель и напрямую.
#   domain-check.sh example.com
# Показывает: адреса домена (через DNS роутера и через DoH в туннеле), правила набора (TUN_DOMAINS / DIRECT_DOMAINS /
# UI_DOMAINS), попали ли адреса в ipset, ответ HTTPS через активный туннель и через WAN, итог: «блокируется напрямую»,
# «работает везде», «не работает и через туннель» и т.п. Ничего не меняет.
DD=${DD:-/data/awg}
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
STATEF=${STATEF:-${AWG_RUN:-/run}/awg-state}
d=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | sed -E 's#^[a-z]+://##; s#[/:].*$##; s/\.$//')
if ! printf '%s' "$d" | grep -Eq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$'; then
  echo "использование: domain-check.sh ДОМЕН (например youtube.com)"; exit 2
fi
c_ok(){ echo "OK     $*"; }; c_warn(){ echo "WARN   $*"; }; c_fail(){ echo "FAIL   $*"; }; c_info(){ echo "       $*"; }

# домен попадает под правило, если совпадает с элементом списка или является его поддоменом
match(){ local x; for x in $2; do x=${x#.}; [ "$1" = "$x" ] && return 0; case "$1" in *."$x") return 0;; esac; done; return 1; }

active=$(sed -n 's/^ACTIVE=//p' "$STATEF" 2>/dev/null)
[ -z "$active" ] && [ -n "${TABLE:-}" ] && active=$(ip -4 route show table "$TABLE" 2>/dev/null | awk '/^default dev awg/{print $3; exit}')
wan=${WANIF:-$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}

echo "Домен: $d"
echo "Активный туннель: ${active:-нет}, WAN: ${wan:-?}"
echo

echo "== Правила набора"
rule=none
if match "$d" "${DIRECT_DOMAINS:-}"; then rule=direct; c_info "в DIRECT_DOMAINS: клиенты под PBR ходят на него напрямую, мимо туннеля"; fi
if match "$d" "${TUN_DOMAINS:-}"; then [ $rule = none ] && rule=tun; c_info "в TUN_DOMAINS: клиенты ${TUN_CLIENTS:-всей LAN} ходят на него через туннель даже без PBR"; fi
if [ "${UI_FIX:-no}" = yes ] && match "$d" "${UI_DOMAINS:-ui.com}"; then c_info "в UI_DOMAINS: соединения самого роутера (облако UniFi) идут через туннель"; fi
[ $rule = none ] && c_info "в списках набора нет: устройства под PBR — через туннель, остальные — напрямую"
echo

echo "== Адреса"
loc=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
if [ -n "$loc" ]; then c_ok "DNS роутера: $loc"; else c_warn "DNS роутера не вернул IPv4-адресов"; fi
tun_ips=""
if [ -n "$active" ]; then
  j=$(curl -s -4 -m 8 --interface "$active" -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$d&type=A" 2>/dev/null)
  tun_ips=$(printf '%s' "$j" | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | cut -d'"' -f4 | sort -u | tr '\n' ' ')
  if [ -n "$tun_ips" ]; then c_ok "DoH через $active: $tun_ips"; else c_warn "DoH через $active не ответил"; fi
  if [ -n "$loc" ] && [ -n "$tun_ips" ]; then
    common=0; for a in $loc; do case " $tun_ips " in *" $a "*) common=1;; esac; done
    [ $common = 0 ] && c_warn "адреса через DNS роутера и через туннель не пересекаются: возможна подмена DNS у провайдера или геобалансировка (CDN)"
  fi
fi
for a in $loc; do
  for s in AWG_DOM AWG_DIRECT AWG_UI; do
    ipset test "$s" "$a" >/dev/null 2>&1 && c_info "$a в наборе $s"
  done
done
if [ $rule = tun ] && [ -n "$loc" ]; then
  hit=0; for a in $loc; do ipset test AWG_DOM "$a" >/dev/null 2>&1 && hit=1; done
  [ $hit = 0 ] && c_warn "адресов нет в AWG_DOM: набор наполняется, когда клиент спрашивает имя у DNS роутера (у клиента не должен стоять свой DNS/DoH)"
fi
echo

echo "== Доступность (HTTPS, код ответа и время)"
probe(){ # $1 — интерфейс; печатает «код время»
  curl -s -4 -o /dev/null -m 10 --connect-timeout 5 ${1:+--interface "$1"} -w '%{http_code} %{time_total}' "https://$d/" 2>/dev/null
}
t_res=""; w_res=""
if [ -n "$active" ]; then
  t_res=$(probe "$active"); t_code=${t_res%% *}
  if [ -n "$t_code" ] && [ "$t_code" != 000 ]; then c_ok "через туннель $active: HTTP $t_code за ${t_res#* } с"; else c_fail "через туннель $active: нет ответа"; fi
fi
if [ -n "$wan" ]; then
  w_res=$(probe "$wan"); w_code=${w_res%% *}
  if [ -n "$w_code" ] && [ "$w_code" != 000 ]; then c_ok "напрямую через $wan: HTTP $w_code за ${w_res#* } с"; else c_fail "напрямую через $wan: нет ответа"; fi
fi
echo

t_ok=0; w_ok=0
[ -n "${t_code:-}" ] && [ "${t_code:-000}" != 000 ] && t_ok=1
[ -n "${w_code:-}" ] && [ "${w_code:-000}" != 000 ] && w_ok=1
echo "== Итог"
if [ $t_ok = 1 ] && [ $w_ok = 0 ]; then
  echo "Напрямую не открывается, через туннель — да."
  [ $rule = direct ] && echo "Домен в DIRECT_DOMAINS: уберите его оттуда, иначе клиенты под PBR его не откроют."
  [ $rule = none ] && echo "Устройствам вне PBR он недоступен. Чтобы открывался у всех: добавьте в «Домены через туннель» (TUN_DOMAINS)."
  exit 0
elif [ $t_ok = 1 ] && [ $w_ok = 1 ]; then
  echo "Открывается и через туннель, и напрямую."
  [ $rule = tun ] && echo "Через туннель его можно не пускать (если не нужна смена страны): уберите из TUN_DOMAINS."
  exit 0
elif [ $t_ok = 0 ] && [ $w_ok = 1 ]; then
  echo "Через туннель не открывается, напрямую — да: сайт может блокировать адрес VPS или страну сервера."
  echo "Если сайт должен идти мимо туннеля — добавьте его в «Домены напрямую» (DIRECT_DOMAINS)."
  exit 1
else
  if [ -z "$loc$tun_ips" ]; then echo "Домен не резолвится: проверьте имя."; else echo "Не открывается ни через туннель, ни напрямую: сайт недоступен или не отвечает по HTTPS."; fi
  exit 1
fi
