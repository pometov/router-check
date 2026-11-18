#!/bin/sh
# Проверка VPN (sing-box) на роутере EasyWRT/OpenWrt. Ничего не меняет, только читает.
# Запуск на роутере по ssh:  curl -fsSL https://raw.githubusercontent.com/pometov/router-check/main/check.sh | sh

CFG=/etc/sing-box/config.json
OK=0; BAD=0; WARN=0
g='\033[32m'; r='\033[31m'; y='\033[33m'; n='\033[0m'
ok()   { OK=$((OK+1));     printf "${g}[ OK ]${n} %s\n" "$1"; }
bad()  { BAD=$((BAD+1));   printf "${r}[FAIL]${n} %s\n       -> %s\n" "$1" "$2"; }
warn() { WARN=$((WARN+1)); printf "${y}[WARN]${n} %s\n" "$1"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi; }

echo "== Роутер: $(grep '^VERSION=' /etc/os-release | cut -d'"' -f2), аптайм: $(uptime | sed 's/^.* up \(.*\), *load.*/\1/'), $(date '+%F %T')"

echo; echo "== Файлы и автозапуск"
chk "Автообновление прошивки выключено (иначе оно стирает sing-box)" \
    '[ "$(uci -q get autoupdate.main.enable)" != 1 ]' \
    "uci set autoupdate.main.enable=0; uci commit autoupdate"
chk "sing-box установлен: $(/usr/bin/sing-box version 2>/dev/null | head -1)" '[ -x /usr/bin/sing-box ]' "нет /usr/bin/sing-box - прошивка стёрла файлы, нужно восстановление"
chk "Конфиг $CFG валиден" "[ -f $CFG ] && /usr/bin/sing-box check -c $CFG >/dev/null 2>&1" "конфиг пропал или с ошибкой"
chk "sing-box в автозапуске" '[ -x /etc/init.d/sing-box ] && ls /etc/rc.d/S*sing-box >/dev/null 2>&1' "/etc/init.d/sing-box enable"
chk "getdomains (список доменов Russia) в автозапуске" '[ -x /etc/init.d/getdomains ] && ls /etc/rc.d/S*getdomains >/dev/null 2>&1' "/etc/init.d/getdomains enable"
chk "Hotplug-маршрут 30-vpnroute" '[ -x /etc/hotplug.d/iface/30-vpnroute ]' "после перезагрузки маршрут в tun0 не поднимется"

echo; echo "== Работа сервиса"
chk "Процесс sing-box запущен" 'ps | grep -q "[s]ing-box run"' "/etc/init.d/sing-box restart; logread | grep sing-box | tail"
chk "Интерфейс tun0 поднят" 'ip link show tun0 >/dev/null 2>&1' "sing-box не создал tun0, смотри logread"
chk "Правило fwmark 0x1 -> таблица vpn" 'ip rule | grep -q "fwmark 0x1.*lookup vpn"' "/etc/init.d/network restart"
chk "Маршрут default dev tun0 в таблице vpn" 'ip route show table vpn | grep -q "default dev tun0"' "ip route add table vpn default dev tun0"
chk "Flow offloading выключен (иначе трафик идёт мимо VPN)" \
    '[ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" != 1 ] && [ "$(uci -q get firewall.@defaults[0].flow_offloading)" != 1 ]' \
    "uci set firewall.@defaults[0].flow_offloading=0; uci set firewall.@defaults[0].flow_offloading_hw=0; uci commit firewall; /etc/init.d/firewall restart"
chk "Правила маркировки трафика в iptables" '[ "$(iptables -t mangle -S PREROUTING 2>/dev/null | grep -c "set-xmark 0x1")" -ge 2 ]' "/etc/init.d/firewall restart"
for s in vpn_subnet vpn_domains; do
  chk "ipset $s существует" "ipset list $s >/dev/null 2>&1" "/etc/init.d/firewall restart"
done
chk "Список доменов Russia загружен ($(wc -l < /tmp/dnsmasq.d/domains.lst 2>/dev/null || echo 0) строк)" '[ "$(wc -c < /tmp/dnsmasq.d/domains.lst 2>/dev/null || echo 0)" -gt 1000 ]' "/etc/init.d/getdomains start"
chk "dnsmasq складывает домены в ipset" 'cat /var/etc/dnsmasq.conf.* 2>/dev/null | grep -q "^ipset="' "в конфиге dnsmasq нет ipset="

echo; echo "== Трафик"
ip=$(nslookup github.com 127.0.0.1 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | head -1)
if [ -n "$ip" ]; then
  ok "DNS роутера резолвит github.com ($ip)"
  if ipset test vpn_domains "$ip" 2>&1 | grep -q "is in set" || ipset test vpn_subnet "$ip" 2>&1 | grep -q "is in set"; then
    ok "github.com попадает в VPN-ipset"
  else bad "github.com не попал в VPN-ipset" "проверь dnsmasq и getdomains"; fi
else bad "DNS роутера не резолвит github.com" "проверь интернет и dnsmasq"; fi

t=$(curl -s -m 15 --interface tun0 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
tip=$(echo "$t" | sed -n 's/^ip=//p'); tloc=$(echo "$t" | sed -n 's/^loc=//p')
if [ -n "$tip" ] && [ "$tloc" != RU ]; then ok "Выход через туннель: $tip ($tloc)"
else bad "Через туннель нет выхода в интернет" "ответ: '${tip}' '${tloc}'; смотри logread | grep sing-box"; fi
d=$(curl -s -m 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
echo "       (прямой выход без VPN: $(echo "$d" | sed -n 's/^ip=//p') $(echo "$d" | sed -n 's/^loc=//p') - тут и должен быть RU)"

echo; echo "== Серверы из конфига"
if [ -f $CFG ]; then
  sed -n '/"outbounds"/,$p' $CFG | awk '
    /"type":/        { gsub(/[",]/, "", $2); t = $2 }
    /"server":/      { gsub(/[",]/, "", $2); s = $2 }
    /"server_port":/ { gsub(/[",]/, "", $2); print t, s, $2 }' > /tmp/check-servers.$$
  while read -r type srv port; do
    case "$type" in
      hysteria2) echo "       $srv:$port (hysteria2, UDP) - снаружи не проверить, живость видна по выходу через туннель выше" ;;
      *) curl -sk -m 10 -o /dev/null "https://$srv:$port"; rc=$?
         case $rc in 6|7|28) bad "$srv:$port ($type) недоступен, curl код $rc" "сервер лежит или заблокирован" ;;
                      *) ok "$srv:$port ($type) отвечает" ;; esac ;;
    esac
  done < /tmp/check-servers.$$
  rm -f /tmp/check-servers.$$
fi
e=$(logread 2>/dev/null | grep sing-box | tail -300 | grep -ci ERROR)
if [ "$e" -eq 0 ]; then ok "В логе sing-box нет ERROR"
else warn "В логе sing-box ERROR: $e, последняя: $(logread | grep sing-box | grep -i ERROR | tail -1 | cut -c1-150)"; fi

echo
if [ "$BAD" -gt 0 ]; then printf "${r}ИТОГ: ЕСТЬ ПРОБЛЕМЫ - ошибок: $BAD, предупреждений: $WARN. Скопируй всё, что выше, и пришли.${n}\n"
elif [ "$WARN" -gt 0 ]; then printf "${y}ИТОГ: работает, предупреждений: $WARN${n}\n"
else printf "${g}ИТОГ: всё в порядке${n}\n"; fi
