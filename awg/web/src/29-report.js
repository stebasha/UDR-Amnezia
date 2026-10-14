  // отчёт за неделю / 30 дней (#41): каналы, скорость, маршруты, трафик по устройствам
  function reportCard() {
    const box = el('div', { class: 'stack' }, el('div', { class: 'muted small' }, T('Загрузка…')));
    let days = 7;
    const seg = el('div', { class: 'seg' });
    const pct = (v) => (v == null ? '—' : v + '%');
    const tbl = (heads, rows) => el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
      el('thead', null, el('tr', null, heads.map((x, i) => el('th', { class: i ? 'r' : '' }, x)))),
      el('tbody', null, rows.map((r) => el('tr', null, r.map((x, i) => el('td', { class: i ? 'r mono small' : '' }, x)))))));
    const load = async () => {
      let r;
      try { r = await api('/api/report?days=' + days); } catch (e) { replace(box, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, String(e.message || e)))); return; }
      const m = r.main;
      const parts = [
        el('div', { class: 'row small' },
          el('span', null, T('Основной канал '), el('b', null, r.main_name), ': ', el('b', null, pct(m.on_main_pct)), T(' времени')),
          el('span', { class: 'muted' }, T('вне его ') + fmtDur(m.off_main_sec) + T(' · переключений ') + (m.switch + m.degrade) + T(' · возвратов ') + m.return),
          r.coverage < 90 ? el('span', { class: 'badge warn' }, T('данных ') + r.coverage + '%') : null),
      ];
      if (r.tunnels.length) parts.push(tbl([T('Канал'), T('Доступность'), 'RTT', T('Потери'), T('Трафик'), T('Активен')],
        r.tunnels.map((t) => [el('b', null, t.label || t.name), pct(t.avail), t.rtt == null ? '—' : t.rtt + T(' мс'), pct(t.loss), fmtBytes(t.bytes), fmtDur(t.active_min * 60)])));
      if (r.speed.length) parts.push(el('div', null, el('div', { class: 'small muted' }, T('Скорость — среднее по замерам')),
        tbl([T('Интерфейс'), T('Загрузка'), T('Отдача'), T('Задержка'), T('Замеров')],
          r.speed.map((s) => [s.iface, fmtBits(s.down_bps), fmtBits(s.up_bps), s.ping_ms ? s.ping_ms + T(' мс') : '—', String(s.n)]))));
      if (r.routes.length) parts.push(el('div', null, el('div', { class: 'small muted' }, T('Дополнительные маршруты')),
        tbl([T('Маршрут'), T('На первом канале'), T('Переключений'), T('Время по каналам')],
          r.routes.map((x) => [el('b', null, x.label || x.id), pct(x.first_pct), String(x.switch),
            x.on.map((o) => (o.tunnel || T('без канала')) + ' ' + fmtDur(o.minutes * 60)).join(' · ') || '—']))));
      const acct = el('input', { type: 'checkbox', checked: r.acct });
      acct.addEventListener('change', async () => {
        try { const x = await api('/api/settings', { values: { TRAFFIC_ACCT: acct.checked ? 'yes' : 'no' } }); ok(TM(x.msg.split('\n').pop() || T('Сохранено'))); if (SETTINGS_CACHE) SETTINGS_CACHE.values.TRAFFIC_ACCT = acct.checked ? 'yes' : 'no'; } catch (e) { acct.checked = !acct.checked; err(e); }
      });
      parts.push(el('div', null,
        el('label', { class: 'row' }, el('span', { class: 'switch' }, acct, el('span', { class: 'knob' })), el('b', null, T('Трафик через туннели по устройствам')),
          el('span', { class: 'muted small' }, T('счётчики в ipset; на трафик не влияют; данные раз в 10 минут'))),
        r.acct ? (r.devices.length ? tbl([T('Устройство'), T('Из туннеля'), T('В туннель')],
          r.devices.map((d) => [el('span', null, el('b', null, d.name || d.ip), d.name ? el('span', { class: 'muted small' }, ' ' + d.ip) : null), fmtBytes(d.down), fmtBytes(d.up)]))
          : el('div', { class: 'muted small' }, T('Пока нет данных — первые появятся через 10 минут.'))) : null));
      replace(box, parts);
    };
    const segBtn = (d, t) => el('button', { class: d === days ? 'on' : '', onclick: (e) => { days = d; seg.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b === e.currentTarget)); load(); } }, t);
    add(seg, [segBtn(7, T('7 дн')), segBtn(30, T('30 дн'))]);
    load();
    return card(T('Отчёт'), box, { icon: 'okc', right: seg });
  }
