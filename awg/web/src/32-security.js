  // ===================================================================== БЕЗОПАСНОСТЬ (1.10)
  // разбор: что открыто в интернет, кто стучится, что поменять в UniFi; своя защита входящих — по желанию
  Object.assign(SPEC, {
    SEC_PROTECT: { t: 'bool', hint: T('Свои правила роутера для пакетов из интернета: правила UniFi не меняются. Выключить — правила убираются сразу.') },
    SEC_GEO_ALLOW: { t: 'text', ph: 'ru', hint: T('Коды стран через пробел. На порты ниже подключиться можно только из них.') },
    SEC_GEO_PORTS: { t: 'text', ph: '8123 44300', hint: T('Порты WAN (как в пробросе UniFi), куда пускать только из разрешённых стран: вход в NAS, Home Assistant, почта по паролю, консоль 443. Не добавляйте 25 (почта приходит со всего мира) и 80 (Let\'s Encrypt). Если сами уезжаете за границу — добавьте страну или зайдите через VPN-сервер роутера.') },
    SEC_TRAP: { t: 'bool', hint: T('Кто стучится на порты-ловушки (Telnet, RDP, SMB, базы данных…) — сканер: его адрес блокируется целиком, и на проброшенные порты тоже. Открытые и проброшенные порты ловушками не бывают.') },
    SEC_TRAP_PORTS: { t: 'text', hint: T('До 15 портов. Открытые на роутере и проброшенные исключаются сами.') },
    SEC_RATE: { t: 'num', unit: T('в минуту'), hint: T('Больше стольких новых соединений с одного адреса на проброшенные порты — подбор паролей: адрес блокируется. 0 — выключено.') },
    SEC_BAN_HOURS: { t: 'num', unit: T('ч'), hint: T('На сколько блокировать адрес.') },
    SEC_ALLOW_IPS: { t: 'list', ph: '203.0.113.10\n198.51.100.0/24', hint: T('Не блокируются никогда (например, рабочий адрес). Частные сети, адрес VPS и серверы туннелей — всегда.') },
  });
  const SEV = { crit: ['crit', 'alert', T('Исправить')], warn: ['warn', 'alert', T('Стоит поправить')], info: ['info', 'info', T('К сведению')], ok: ['ok', 'okc', T('Хорошо')] };
  const KIND_RU = { admin: T('управление'), login: T('вход по паролю'), mail: T('почта'), web: T('сайт'), media: T('медиа'), vpn: 'VPN' };
  PAGES.security = async function (main) {
    const again = el('button', { class: 'btn' }, icon('refresh'), T('Проверить заново'));
    add(main, head(T('Безопасность'), again));
    const body = el('div', { class: 'stack' }, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), T('проверяю правила, журналы и соединения…')));
    main.appendChild(body);
    const load = async (fresh) => {
      let r, s;
      try { [r, s] = await Promise.all([api('/api/security' + (fresh ? '?fresh=1' : '')), settings(true)]); } catch (e) { replace(body, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); return; }
      paint(r, s);
    };
    again.addEventListener('click', () => busy(again, () => load(true)));
    function paint(r, s) {
      const d = r.data, f = r.findings, pr = d.protect;
      const n = (k) => f.filter((x) => x.sev === k).length;
      const tone = r.score >= 85 ? 'ok' : r.score >= 60 ? 'warn' : 'crit';
      const summary = card(T('Итог'), el('div', { class: 'row wrap between' },
        el('div', null, el('div', { class: 'score ' + tone }, String(r.score), el('span', { class: 'small muted' }, ' / 100')),
          el('div', { class: 'small muted' }, T('Проверено: ') + new Date(d.t * 1000).toLocaleString())),
        el('div', { class: 'row wrap' },
          el('span', { class: 'badge crit' }, T('исправить: ') + n('crit')), el('span', { class: 'badge warn' }, T('стоит поправить: ') + n('warn')),
          el('span', { class: 'badge' }, T('к сведению: ') + n('info')), el('span', { class: 'badge ok' }, T('хорошо: ') + n('ok')))),
      { icon: 'shield' });
      const list = card(T('Что найдено и что делать'), el('div', { class: 'stack' }, f.map((x) => {
        const sv = SEV[x.sev];
        return el('div', { class: 'alert ' + sv[0] }, icon(sv[1]), el('div', null,
          el('b', null, x.title), el('span', { class: 'small muted' }, ' · ' + sv[2]),
          x.text ? el('div', { class: 'small' }, x.text) : null,
          x.fix ? el('div', { class: 'small' }, el('b', null, T('Что сделать: ')), x.fix) : null,
          x.where ? el('div', { class: 'small muted' }, T('Где: ') + x.where) : null));
      })), { icon: 'search' });
      const days = Math.max(1, Math.floor(d.uptime / 86400));
      const geoP = (pr.on && pr.geo_allow ? pr.geo_ports.split(/\s+/) : []);
      const fw = card(T('Проброс портов'), d.forwards.length ? el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
        el('thead', null, el('tr', null, ['WAN', T('Куда'), T('Служба'), T('Пакетов'), T('Ограничен')].map((h) => el('th', null, h)))),
        el('tbody', null, d.forwards.map((x) => el('tr', null,
          el('td', { class: 'mono' }, x.port + (x.port_end !== x.port ? '–' + x.port_end : '') + '/' + x.proto),
          el('td', { class: 'mono' }, x.to + ':' + x.to_port),
          el('td', null, x.service || '—', x.kind ? el('div', { class: 'small muted' }, KIND_RU[x.kind] || x.kind) : null),
          el('td', null, String(x.pkts)),
          el('td', null, geoP.includes(String(x.port)) ? el('span', { class: 'badge ok' }, T('страны: ') + pr.geo_allow.toUpperCase()) : x.restricted ? el('span', { class: 'badge ok' }, T('по адресам (UniFi)')) : el('span', { class: 'badge warn' }, T('всем')))))))) :
        el('p', { class: 'muted' }, T('Проброса портов нет.')),
      { icon: 'route', flush: !!d.forwards.length, right: el('span', { class: 'small muted' }, T('счётчики — за ') + days + T(' дн.')) });
      const lc = d.local;
      const wan = card(T('Что принимает сам роутер из интернета'), lc ? el('dl', { class: 'kv' },
        lc.accept.map((a) => [el('dt', null, a.kind === 'console' ? T('Консоль UniFi') : a.kind === 'wireguard' ? T('VPN-сервер WireGuard') : T('Правило пользователя')),
          el('dd', null, el('span', { class: 'mono' }, (a.dports.join(', ') || T('все')) + (a.sports.length ? T(' (с порта ') + a.sports.join(', ') + ')' : '')), ' · ' + a.pkts + T(' пакетов'))]),
        el('dt', null, T('Отброшено непрошеных')), el('dd', null, String(lc.drop)),
        el('dt', null, T('Отброшено ошибочных')), el('dd', null, String(lc.invalid))) : el('p', { class: 'muted' }, T('Правила UniFi не прочитаны.')), { icon: 'router' });
      const c = d.conns;
      const top = (arr, k) => arr.length ? arr.map((x) => el('div', { class: 'row between small' }, el('span', { class: 'mono' }, String(x[k])), el('b', null, String(x.n)))) : el('span', { class: 'muted small' }, '—');
      const now = card(T('Снаружи подключены сейчас'), el('div', { class: 'grid g-2e' },
        el('div', null, el('div', { class: 'small muted' }, T('по портам')), top(c.ports, 'port')),
        el('div', null, el('div', { class: 'small muted' }, T('по адресам')), top(c.src, 'ip'))), { icon: 'activity', right: el('span', { class: 'small muted' }, T('всего: ') + c.total) });
      const ips = d.ips;
      const ipsc = card('IPS / honeypot', el('div', null,
        el('dl', { class: 'kv' },
          el('dt', null, 'IPS'), el('dd', null, ips.running ? el('span', { class: 'badge ok' }, T('работает') + (ips.profile ? ' · ' + ips.profile : '')) : el('span', { class: 'badge warn' }, T('выключена'))),
          el('dt', null, 'Honeypot'), el('dd', null, d.honeypot ? el('span', { class: 'badge ok' }, T('включён')) : T('нет')),
          el('dt', null, T('Событий на роутере')), el('dd', null, ips.file ? String(ips.alerts) : T('не хранятся'))),
        ips.sig.length ? el('div', { class: 'stack small' }, ips.sig.map((x) => el('div', { class: 'row between' }, el('span', null, x.sig, x.cat ? el('span', { class: 'muted' }, ' · ' + x.cat) : null), el('b', null, String(x.n))))) : null), { icon: 'shield' });
      // ---- своя защита
      const sug = r.suggest;
      const fill = el('button', { class: 'btn' }, icon('wrench', 'sm'), T('Подставить рекомендуемое'));
      fill.addEventListener('click', async () => {
        const cc = (s.values.SEC_GEO_ALLOW || 'ru');
        if (!await confirmBox(T('Включить защиту входящих?'), T('Порты только из стран ') + cc.toUpperCase() + ': ' + (sug.SEC_GEO_PORTS || T('нет')) + T('; блокировка сканеров и подбора паролей (больше 30 соединений в минуту). Если сами бываете за границей — добавьте страну или заходите через VPN-сервер роутера.'), T('Включить'))) return;
        const vals = { SEC_PROTECT: 'yes', SEC_TRAP: 'yes', SEC_RATE: sug.SEC_RATE };
        if (sug.SEC_GEO_PORTS) { vals.SEC_GEO_PORTS = sug.SEC_GEO_PORTS; vals.SEC_GEO_ALLOW = cc; }
        try { ok((await api('/api/settings', { values: vals })).msg); setTimeout(() => load(true), 3000); } catch (e) { err(e); }
      });
      const form = settingsForm(T('Защита входящих'), 'lock', ['SEC_PROTECT', 'SEC_GEO_ALLOW', 'SEC_GEO_PORTS', 'SEC_TRAP', 'SEC_RATE', 'SEC_BAN_HOURS', 'SEC_ALLOW_IPS', 'SEC_TRAP_PORTS'], s,
        el('div', null, el('div', { class: 'alert info' }, icon('info'), el('div', null,
          pr.on ? [el('b', null, T('Включена. ')), T('Заблокировано сейчас: ') + (pr.trap_n + pr.rate_n) + T(' (сканеры ') + pr.trap_n + T(', подбор ') + pr.rate_n + T('); отброшено пакетов: по странам ') + pr.geo_drop + T(', заблокированных ') + pr.ban_drop + '.']
            : T('Выключена. Рекомендуемое: порты управления и входа по паролю — только из вашей страны, блокировка сканеров и подбора паролей.'))),
        el('div', { class: 'row wrap' }, fill)));
      const banRows = pr.banned.map((b) => {
        const un = el('button', { class: 'btn sm' }, T('Снять'));
        un.addEventListener('click', () => busy(un, async () => { try { ok((await api('/api/security/unban', { ip: b.ip })).msg); load(true); } catch (e) { err(e); } }));
        return el('tr', null, el('td', { class: 'mono' }, b.ip), el('td', null, b.why === 'trap' ? T('сканер') : T('подбор')),
          el('td', null, Math.round(b.left / 3600) + T(' ч')), el('td', null, String(b.pkts)), el('td', null, un));
      });
      const bans = pr.on ? card(T('Заблокированные адреса'), banRows.length ? el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
        el('thead', null, el('tr', null, [T('Адрес'), T('За что'), T('Осталось'), T('Пакетов'), ''].map((h) => el('th', null, h)))), el('tbody', null, banRows))) :
        el('p', { class: 'muted' }, T('Пока никого.')), { icon: 'x', flush: !!banRows.length, right: el('span', { class: 'small muted' }, T('за сутки: ') + (pr.day || 0)) }) : null;
      replace(body, summary, list, el('div', { class: 'grid g-2e' }, fw, wan), el('div', { class: 'grid g-2e' }, now, ipsc), form, bans);
    }
    load(false);
  };
