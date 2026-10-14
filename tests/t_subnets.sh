#!/bin/bash
# shellcheck disable=SC2034  # переменные используются в строках проверок (eval)
# subnets.sh (awg-subnets) на заглушке ip с состоянием: правила 6100/6101, маршрут подсети в таблице PBR, уборка лишнего,
# и что в обычном проходе ничего не переписывается. Запуск: bash tests/t_subnets.sh <папка awg>
SRC=$(cd "${1:-$(dirname "$0")/../awg}" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export DD=$T/dd STUB=$T/stub AWG_RUN=$T/run
mkdir -p "$DD" "$STUB" "$AWG_RUN" "$T/bin"
cat > "$T/bin/ip" <<'S'
#!/bin/bash
# заглушка ip: правила — $STUB/rules, таблицы — $STUB/rt-N, подсети VPN-сервера — $STUB/vpn («подсеть интерфейс»)
S=$STUB; echo "ip $*" >> $S/ip.log
[ "$1" = -4 ] && shift
tname(){ [ "$1" = 178 ] && echo 178.wgclt1 || echo "$1"; }
case "$1 $2" in
  "rule show") cat $S/rules 2>/dev/null;;
  "rule add") src=$4; tb=$6; pr=${!#}; sp=""; [ "$7" = suppress_prefixlength ] && sp=" suppress_prefixlength 0"
              printf '%s:\tfrom %s lookup %s%s\n' "$pr" "$src" "$(tname "$tb")" "$sp" >> $S/rules;;
  "rule del") src=$4; pr=$6; n=$(grep -n -m1 -E "^$pr:[[:space:]]+from $src " $S/rules 2>/dev/null | cut -d: -f1)
              [ -n "$n" ] || exit 2; sed -i "${n}d" $S/rules;;
  "route show") if [ "$4" = all ]; then awk -v s="$6" '$1==s {print s" dev "$2" proto kernel scope link"}' $S/vpn 2>/dev/null
                else cat "$S/rt-$4" 2>/dev/null; fi;;
  "route replace") f=$S/rt-${!#}; sed -i "\#^$3 #d" "$f" 2>/dev/null; echo "$3 dev $5 scope link" >> "$f";;
  "route del") sed -i "\#^$3 #d" "$S/rt-$5" 2>/dev/null;;
esac
exit 0
S
printf '#!/bin/bash\nexit 0\n' > "$T/bin/iptables"
chmod 755 "$T"/bin/*; export PATH="$T/bin:$PATH"
printf 'TABLE=178\nEXTRA_SUBNETS="192.168.3.0/24"\n' > "$DD/awg.env"
echo "192.168.3.0/24 wgsrv1" > "$STUB/vpn"
G="bash $SRC/subnets.sh"; fails=0
ck(){ if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fails=$((fails+1)); fi; }
nr(){ grep -c -E "^$1:[[:space:]]+from $2 lookup $3" "$STUB/rules" 2>/dev/null; }

$G apply
ck "подсеть: правило 6100 (локальное остаётся локальным) и 6101 в таблицу PBR" '[ "$(nr 6100 192.168.3.0/24 main)" = 1 ] && [ "$(nr 6101 192.168.3.0/24 178.wgclt1)" = 1 ]'
ck "подсеть: маршрут к клиентам VPN-сервера в таблице PBR" 'grep -qx "192.168.3.0/24 dev wgsrv1 scope link" "$STUB/rt-178"'
: > "$STUB/ip.log"; $G apply
ck "обычный проход: ничего не добавляется и не переписывается (только чтение)" '! grep -qE "rule (add|del)|route (replace|del)" "$STUB/ip.log" && [ "$(grep -c . "$STUB/ip.log")" -le 3 ]'
printf '6100:\tfrom 192.168.3.0/24 lookup main suppress_prefixlength 0\n' >> "$STUB/rules"
$G apply
ck "лишняя копия правила убрана" '[ "$(nr 6100 192.168.3.0/24 main)" = 1 ]'
printf '6101:\tfrom 10.99.0.0/24 lookup 178.wgclt1\n' >> "$STUB/rules"
$G apply
ck "правило подсети не из списка убрано" '[ "$(nr 6101 10.99.0.0/24 178)" = 0 ]'
sed -i 's/^TABLE=178/TABLE=179/' "$DD/awg.env"; $G apply
ck "сменилась таблица PBR: правило 6101 ведёт в новую, старое убрано" '[ "$(nr 6101 192.168.3.0/24 179)" = 1 ] && [ "$(nr 6101 192.168.3.0/24 178)" = 0 ]'
sed -i 's/^EXTRA_SUBNETS=.*/EXTRA_SUBNETS=""/' "$DD/awg.env"; $G apply
ck "подсети убраны из настроек: правила сняты" '! grep -q "192.168.3.0/24" "$STUB/rules"'
echo "== subnets: ошибок $fails"; [ $fails = 0 ]
