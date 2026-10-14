  // ===================================================================== формы настроек
  const SPEC = {
    RECOVER_SEC: { t: 'num', unit: T('с'), hint: T('Сколько основной канал должен проработать стабильно, прежде чем сторож вернётся на него.') },
    QUALITY: { t: 'bool', hint: T('Уходить с канала, если потери или задержка выше порога, а другой канал лучше.') },
    QUALITY_LOSS: { t: 'num', unit: '%', hint: T('Потери пакетов, при которых канал считается плохим.') },
    QUALITY_RTT: { t: 'num', unit: T('мс'), hint: T('Порог задержки; 0 — не учитывать.') },
    MIN_DWELL: { t: 'num', unit: T('с'), hint: T('Пауза после переключения, чтобы каналы не «прыгали».') },
    EXTRA_SUBNETS: { t: 'list', ph: '192.168.3.0/24', hint: T('Подсети VPN-сервера на роутере (WireGuard / L2TP / OpenVPN): их клиенты тоже идут через туннель.') },
    TUN_DOMAINS: { t: 'list', ph: 'youtube.com\ngooglevideo.com', hint: T('Сайты, которые открываются через туннель для всей LAN (или выбранных клиентов) без PBR. Поддомены включаются. Клиенты должны спрашивать DNS у роутера.') },
    TUN_CLIENTS: { t: 'list', ph: '192.168.1.50\n192.168.1.0/28', hint: T('Для кого действуют домены через туннель. Пусто — вся LAN.') },
    DIRECT_DOMAINS: { t: 'list', ph: 'gosuslugi.ru\nsberbank.ru', hint: T('Устройства под PBR откроют эти сайты напрямую, мимо туннеля.') },
    DIRECT_SUBNETS: { t: 'list', ph: '95.173.128.0/19', hint: T('Адреса и подсети, куда устройства под PBR ходят напрямую.') },
    LEAK_GUARD: { t: 'bool', hint: T('Запрет выхода трафика PBR-устройств в WAN мимо туннеля — вторая линия защиты после blackhole.') },
    LEAK_V6: { t: 'choice', opts: [['block', T('Блокировать')], ['route', T('Через туннель')], ['off', T('Не трогать')]], hint: T('IPv6 устройств под PBR: «Блокировать» (по умолчанию) — устройства идут по IPv4 через туннель; «Через туннель» — IPv6 тоже идёт через туннель, если сервер выдал туннелю IPv6-адрес (иначе отклоняется); «Не трогать» — IPv6 идёт мимо туннеля.') },
    LISTS_MODE: { t: 'choice', opts: [['off', T('Всё (как настроено в UniFi)')], ['blocked', T('Только заблокированное')], ['geoip', T('Всё, кроме выбранных стран')]], hint: T('Для устройств под PBR (и дополнительных маршрутов). «Только заблокированное» — через туннель идут только адреса из списков заблокированного, остальное напрямую. «Всё, кроме стран» — напрямую идут только адреса выбранных стран (умный дом с серверами в Китае, местные сервисы), остальное через туннель.') },
    GEO_COUNTRIES: { t: 'text', ph: 'ru cn by kz', hint: T('Коды стран через пробел; их адреса идут напрямую в режиме «Всё, кроме выбранных стран».') },
    LIST_URLS: { t: 'list', ph: 'https://antifilter.download/list/allyouneed.lst', hint: T('Списки заблокированного (по сети IPv4 на строку). Пусто — antifilter.download. Обновляются раз в сутки; не скачались — остаются прежние.') },
    UI_FIX: { t: 'bool', hint: T('Соединения самого роутера с облаком UniFi (unifi.ui.com) — через туннель. Нужно, если ui.com недоступен напрямую.') },
    UI_DOMAINS: { t: 'list', hint: T('Домены облака UniFi.') },
    UI_DNS: { t: 'text', hint: T('DNS-сервер для доменов UniFi (запрос уходит через туннель).') },
    DNS_ALL_TUNNEL: { t: 'bool', hint: T('Все DNS-запросы самого роутера — через туннель (защита от подмены DNS провайдером).') },
    METRICS_PORT: { t: 'num', hint: T('Порт /metrics для Prometheus. Пусто — выключено.') },
  };
  let SETTINGS_CACHE = null;
  async function settings(force) {
    if (!SETTINGS_CACHE || force) SETTINGS_CACHE = await api('/api/settings');
    return SETTINGS_CACHE;
  }
  function settingsForm(title, ic, keys, data, note) {
    const ctl = {};
    const rows = keys.map((k) => {
      const sp = SPEC[k], v = data.values[k] || '';
      let c;
      if (sp.t === 'bool') {
        const inp = el('input', { type: 'checkbox', checked: v === 'yes' });
        c = el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }));
        ctl[k] = () => (inp.checked ? 'yes' : 'no');
      } else if (sp.t === 'choice') {
        const s = el('select', { class: 'input' }, sp.opts.map(([val, name]) => el('option', { value: val, selected: v === val }, name)));
        c = s; ctl[k] = () => s.value;
      } else if (sp.t === 'list') {
        const ta = el('textarea', { class: 'input', placeholder: sp.ph || '', spellcheck: 'false', rows: 3 });
        ta.value = v.split(/\s+/).filter(Boolean).join('\n');
        c = ta; ctl[k] = () => ta.value.split(/[\s,]+/).filter(Boolean).join(' ');
      } else {
        const inp = el('input', { class: 'input', value: v, inputmode: sp.t === 'num' ? 'numeric' : 'text', placeholder: sp.unit || sp.ph || '' });
        c = sp.unit ? el('div', { class: 'input-group' }, inp, el('span', { class: 'muted row' }, sp.unit)) : inp;
        ctl[k] = () => inp.value.trim();
      }
      return el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, TM(data.labels[k] || k)), el('span', null, sp.hint), el('div', { class: 'small muted mono' }, k)),
        el('div', { class: 'ctl' + (sp.t === 'bool' ? ' auto' : '') }, c));
    });
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Применить'));
    const res = el('div', { class: 'res hidden' });
    save.addEventListener('click', () => busy(save, async () => {
      const ch = {};
      for (const k of keys) if (ctl[k]() !== (data.values[k] || '')) ch[k] = ctl[k]();
      if (!Object.keys(ch).length) { toast(T('Изменений нет')); return; }
      try {
        const x = await api('/api/settings', { values: ch });
        Object.assign(data.values, ch);
        res.textContent = x.msg; res.classList.remove('hidden');
        ok(T('Сохранено'));
      } catch (e) { err(e); }
    }));
    return card(title, el('div', null, note || null, rows, res), { icon: ic, foot: save });
  }

  // ===================================================================== МАРШРУТИЗАЦИЯ
  PAGES.routing = async function (main) {
    add(main, head(T('Маршрутизация')));
    const body = el('div', { class: 'stack' }, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), T('загрузка…')));
    main.appendChild(body);
    let d, ov;
    try { [d, ov] = await Promise.all([settings(true), api('/api/overview')]); } catch (e) { replace(body, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); return; }
    updateChrome(ov);
    const p = d.pbr;
    const pbr = card('Policy-Based Routing UniFi', el('div', { class: 'grid g-2e' },
      el('dl', { class: 'kv' },
        el('dt', null, T('Профиль (интерфейс)')), el('dd', null, el('span', { class: 'mono' }, p.RAIL_IF || '—')),
        el('dt', null, T('Таблица')), el('dd', null, el('span', { class: 'mono' }, p.TABLE || '—')),
        el('dt', null, T('Метка (fwmark/mask)')), el('dd', null, el('span', { class: 'mono' }, p.MARK || '—')),
        el('dt', null, T('Приоритет ip rule')), el('dd', null, el('span', { class: 'mono' }, p.PRIO || '—')),
        el('dt', null, 'Kill switch (blackhole)'), el('dd', null, ov.pbr.killswitch ? el('span', { class: 'badge ok' }, T('на месте')) : el('span', { class: 'badge crit' }, T('нет'))),
        el('dt', null, T('Каналы по приоритету')), el('dd', null, [p.MAIN, p.BACKUP].concat((p.TUNNELS_EXTRA || '').split(' ')).filter(Boolean).join(' → '))),
      el('div', null, el('div', { class: 'small muted' }, T('Маршруты в таблице ') + (p.TABLE || '')),
        el('pre', { class: 'res' }, ov.pbr.routes.join('\n') || T('(пусто)')))),
    { icon: 'route', right: el('a', { class: 'btn sm', href: '#/tools' }, T('Проверить')) });
    replace(body,
      el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Какие устройства идут через туннель, задаётся в UniFi Network: Settings → Routing → Policy-Based Routes (профиль '), el('b', null, p.RAIL_IF || '—'), T('). Здесь — то, что работает поверх: домены, исключения, защита от утечек.'))),
      pbr,
      settingsForm(T('Домены через туннель'), 'globe', ['TUN_DOMAINS', 'TUN_CLIENTS'], d),
      settingsForm(T('Исключения: напрямую мимо туннеля'), 'link', ['DIRECT_DOMAINS', 'DIRECT_SUBNETS'], d),
      settingsForm(T('Списки и GeoIP'), 'layers', ['LISTS_MODE', 'GEO_COUNTRIES', 'LIST_URLS'], d, listsStatus()),
      settingsForm(T('Защита от утечек'), 'shield', ['LEAK_GUARD', 'LEAK_V6', 'DNS_ALL_TUNNEL'], d),
      settingsForm(T('VPN-сервер роутера'), 'users', ['EXTRA_SUBNETS'], d),
      settingsForm(T('Облако UniFi'), 'globe', ['UI_FIX', 'UI_DOMAINS', 'UI_DNS'], d));
  };

