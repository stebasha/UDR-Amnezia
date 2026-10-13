  // ===================================================================== ОБЗОР
  PAGES.overview = function (main) {
    const alerts = el('div');
    const kpis = el('div', { class: 'grid g-kpi' });
    const topo = el('div');
    const evs = el('div');
    const svcs = el('div');
    const chartWrap = el('div', { class: 'chart-wrap' });
    const clBox = el('div', { class: 'empty' }, T('загрузка…'));
    const upBox = el('div', { class: 'stack' });
    const drawUp = () => replace(upBox, (S.ov ? S.ov.tunnels : []).map((t) => el('div', null, el('div', { class: 'row small' }, el('span', { class: 'dot ' + dotFor(t.status) }), el('b', null, t.label || t.name), el('span', { class: 'muted' }, ROLE[t.role])), uptimeBar(hist, t.name))));
    const legend = el('div', { class: 'legend' });
    const tunSel = el('select', { class: 'input', 'aria-label': T('Туннель') });
    tunSel.style.width = 'auto'; tunSel.style.height = '30px';
    const seg = el('div', { class: 'seg' });
    const segBtn = (m, t) => el('button', { class: S.histMode === m ? 'on' : '', onclick: (e) => { S.histMode = m; seg.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b === e.currentTarget)); drawMain(); } }, t);
    add(seg, [segBtn('live', T('10 мин')), segBtn('day', T('24 ч')), segBtn('7d', T('7 дн')), segBtn('30d', T('30 дн'))]);
    // выгрузка истории в CSV (#10): за выбранный период (10 минут — как сутки)
    const csv = el('a', { class: 'btn sm ghost icon', title: T('Скачать CSV'), 'aria-label': T('Скачать CSV') }, icon('download', 'sm'));
    csv.addEventListener('click', () => { csv.href = '/api/history.csv?range=' + ({ live: '24h', day: '24h' }[S.histMode] || S.histMode); });
    S.histLong = S.histLong || {};
    const longPts = async (rg) => {
      const c = S.histLong[rg];
      if (!c || Date.now() - c.at > 600000) S.histLong[rg] = { at: Date.now(), hours: (await api('/api/history?range=' + rg)).hours };
      return S.histLong[rg].hours;
    };
    tunSel.addEventListener('change', () => { S.chartTun = tunSel.value; drawMain(); });
    let hist = [];
    add(main, [
      head(T('Обзор'), el('a', { class: 'btn', href: '#/tools' }, icon('stetho'), T('Диагностика')), rebootBtn()),
      alerts, el('div', { class: 'spacer' }), kpis, el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card(T('Схема'), topo, { icon: 'layers' }),
        card(T('События'), evs, { icon: 'activity', flush: true, right: el('a', { class: 'btn sm ghost', href: '#/logs' }, T('Все')) })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card(T('Трафик'), el('div', { class: 'stack' }, chartWrap, legend), { icon: 'activity', id: 'traffic', right: el('div', { class: 'row' }, tunSel, seg, csv) }),
        card(T('Службы'), svcs, { icon: 'cpu', flush: true, right: el('a', { class: 'btn sm ghost', href: '#/settings/services' }, T('Управление')) })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card(T('Клиенты в туннеле'), clBox, { icon: 'users', flush: true, right: el('a', { class: 'btn sm ghost', href: '#/clients' }, T('Все')) }),
        card(T('Доступность каналов'), upBox, { icon: 'okc' })),
    ]);
    function kpi(lbl, ic, val, sub, extra, tone, go, hint) {
      const k = el('button', { class: 'card kpi' + (tone ? ' t-' + tone : ''), type: 'button', title: hint || '', onclick: go },
        el('div', { class: 'kh' }, el('span', { class: 'lbl' }, lbl), el('span', { class: 'kic' }, icon(ic))),
        el('div', { class: 'val' }, val), el('div', { class: 'sub' }, sub || ' '), el('div', { class: 'kx' }, extra || null));
      return k;
    }
    function alertsModal(ov) {
      api('/api/health').then((h) => {
        modal(T('Состояние'), el('div', { class: 'stack' }, alertsBox(ov),
          el('h3', null, T('Роутер')), el('div', { class: 'checks' }, h.checks.map(checkRow))), [], { wide: true });
      }).catch(err);
    }
    function drawMain() {
      const t = S.chartTun;
      if (!t) return;
      if (S.histMode === 'live') {
        const q = S.live[t] || [];
        drawChart(chartWrap, [
          { name: T('Получено'), color: '--chart-rx', fill: true, points: q.map((p) => [p[0], p[1]]) },
          { name: T('Отправлено'), color: '--chart-tx', points: q.map((p) => [p[0], p[2]]) }]);
      } else if (S.histMode === 'day') {
        const pts = hist.filter((p) => p.tun && p.tun[t]);
        drawChart(chartWrap, [
          { name: T('Получено'), color: '--chart-rx', fill: true, points: pts.map((p) => [p.t, p.tun[t].rx]) },
          { name: T('Отправлено'), color: '--chart-tx', points: pts.map((p) => [p.t, p.tun[t].tx]) }],
        { empty: T('История копится раз в минуту — загляните позже') });
      } else {
        const mode = S.histMode;
        longPts(mode).then((hs) => {
          if (S.histMode !== mode || S.chartTun !== t) return;
          const pts = hs.filter((p) => p.tun && p.tun[t]);
          drawChart(chartWrap, [
            { name: T('Получено'), color: '--chart-rx', fill: true, points: pts.map((p) => [p.t, p.tun[t].rx]) },
            { name: T('Отправлено'), color: '--chart-tx', points: pts.map((p) => [p.t, p.tun[t].tx]) }],
          { empty: T('Сводки копятся раз в час — загляните позже') });
        }).catch(err);
      }
      const r = lastRate(t);
      replace(legend, el('span', null, el('i', null), T('Получено '), el('b', null, r ? fmtBits(r[1]) : '—')),
        el('span', null, el('i', null), T('Отправлено '), el('b', null, r ? fmtBits(r[2]) : '—')));
      const is = legend.querySelectorAll('i');
      is[0].style.background = cssVar('--chart-rx'); is[1].style.background = cssVar('--chart-tx');
    }
    S.redraw = drawMain;
    function render(ov) {
      S.ov = ov;
      updateChrome(ov);
      replace(alerts, alertsBox(ov));
      const act = ov.tunnels.find((t) => t.active);
      const r = act ? lastRate(act.name) : null;
      const lv = { ok: ['ok', T('Работает')], warn: ['warn', T('Внимание')], crit: ['crit', T('Проблема')] }[ov.level];
      const memPct = ov.mem.total_mb ? Math.round(ov.mem.used_mb * 100 / ov.mem.total_mb) : 0;
      const sy = ov.sys || {};
      const nAl = ov.alerts.filter((a) => a[0] !== 'info').length;
      const onMain = ov.stats.on_main_pct;
      const bar = (pct) => { const i = el('i'); i.style.width = Math.max(0, Math.min(100, pct)) + '%'; return el('div', { class: 'bar' }, i); };
      replace(kpis,
        kpi(T('Состояние'), 'shield', [el('span', { class: 'dot ' + lv[0] + ' pulse' }), el('span', { class: 't' }, lv[1])], nAl ? T('замечаний: ') + nAl : T('без замечаний'), null, lv[0], () => alertsModal(ov), T('Все замечания')),
        kpi(T('Канал'), 'tunnel', el('span', { class: 't' }, act ? (act.label || act.name) : T('нет')), act ? (act.name + (ov.forced ? T(' · выбран вручную') : T(' · авто'))) : T('трафик PBR заблокирован'), null, act ? 'ok' : 'crit', () => { location.hash = '#/tunnels'; }, T('Туннели')),
        kpi('Handshake', 'clock', el('span', { class: 't' }, act && act.handshake >= 0 ? fmtAge(act.handshake) : '—'), act ? qText(act) : '', null, act && act.handshake >= 0 && act.handshake < 180 ? 'ok' : 'warn', () => { if (act) tunnelTest(act); }, T('Тест активного канала')),
        kpi(T('Скорость'), 'activity', el('span', { class: 't' }, r ? fmtBits(r[1]) : '—'), r ? '↑ ' + fmtBits(r[2]) : T('нет данных'), null, '', () => { $('#traffic').scrollIntoView({ behavior: 'smooth' }); }, T('График трафика')),
        kpi(T('За 7 дней'), 'okc', el('span', { class: 't' }, onMain + '%'), T('на основном · переключений: ') + ov.stats.switch, bar(onMain), onMain >= 99 ? 'ok' : 'warn', () => { location.hash = '#/logs/events'; }, T('События и статистика')),
        kpi(T('Роутер'), 'cpu', el('span', { class: 't' }, 'CPU ' + Math.round(sy.cpu || 0) + '%'), T('память ') + memPct + '%' + (sy.temp ? ' · ' + Math.round(sy.temp) + '°C' : '') + ' · /data ' + fmtMB(ov.data_free_mb), bar(memPct), sy.level === 'ok' ? 'ok' : sy.level, () => { location.hash = '#/system'; }, T('Процессор, память, диск, температура')));
      replace(topo, topology(ov));
      drawUp();
      replace(evs, ov.events.length ? ov.events.slice(0, 9).map(evRow) : el('div', { class: 'empty' }, T('Событий пока нет')));
      replace(svcs, Object.entries(ov.services).filter(([, s]) => s.installed).map(([u, s]) =>
        el('div', { class: 'svc' }, el('span', { class: 'dot ' + (s.active ? 'ok' : 'crit') }), el('span', { class: 'nm' }, u.replace('awg-', '')), el('span', { class: 'ds' }, TM(s.info)),
          el('span', { class: 'badge ' + (s.active ? 'ok' : 'crit') }, s.active ? T('работает') : T('стоит')))));
      const names = ov.tunnels.map((t) => t.name);
      if (!S.chartTun || !names.includes(S.chartTun)) S.chartTun = (act || ov.tunnels[0] || {}).name || '';
      if (Array.from(tunSel.options).map((o) => o.value).join() !== names.join()) {
        replace(tunSel, ov.tunnels.map((t) => el('option', { value: t.name }, t.label ? t.label + ' (' + t.name + ')' : t.name)));
      }
      tunSel.value = S.chartTun;
    }
    every(5000, async () => { try { render(await api('/api/overview')); } catch (e) { if (!(e instanceof ApiErr && e.auth)) replace(alerts, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); } });
    every(2000, async () => { S.live = (await api('/api/live')).live; if (S.histMode === 'live') drawMain(); });
    every(60000, async () => { hist = S.hist = (await api('/api/history')).points; if (S.histMode === 'day') drawMain(); drawUp(); });
    every(10000, async () => { const c = await api('/api/clients'); replace(clBox, clientsTable(c.clients.slice(0, 6), true)); clBox.className = ''; });
    const ro = new ResizeObserver(() => drawMain());
    ro.observe(chartWrap);
  };

