  // ===================================================================== РОУТЕР (железо)
  function gauge(pct, label, sub, tone) {
    pct = Math.max(0, Math.min(100, +pct || 0));
    const r = 34, c = 2 * Math.PI * r;
    const ring = sv('svg', { viewBox: '0 0 84 84', class: 'gauge', 'aria-hidden': 'true' },
      sv('circle', { cx: 42, cy: 42, r, class: 'gb' }),
      sv('circle', { cx: 42, cy: 42, r, class: 'gf ' + (tone || ''), 'stroke-dasharray': (c * pct / 100).toFixed(1) + ' ' + c.toFixed(1), transform: 'rotate(-90 42 42)' }));
    return el('div', { class: 'gw' }, el('div', { class: 'gr' }, ring, el('div', { class: 'gv' }, Math.round(pct) + '%')),
      el('div', { class: 'gl' }, el('b', null, label), el('span', { class: 'muted small' }, sub)));
  }
  const toneOf = (p, w, c) => (p >= c ? 'crit' : p >= w ? 'warn' : 'ok');
  PAGES.system = function (main) {
    const gauges = el('div', { class: 'grid g-gauge' });
    const checks = el('div', { class: 'checks' });
    const cpuC = el('div', { class: 'chart-wrap sm' }), memC = el('div', { class: 'chart-wrap sm' }), tC = el('div', { class: 'chart-wrap sm' }), ctC = el('div', { class: 'chart-wrap sm' });
    const disks = el('div'), procs = el('div'), info = el('div');
    add(main, [head(T('Роутер'), el('button', { class: 'btn', onclick: () => load() }, icon('refresh', 'sm'), T('Обновить')), rebootBtn()),
      gauges, el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2' },
        card(T('Проверки железа'), checks, { icon: 'stetho' }),
        card(T('Сведения'), info, { icon: 'info' })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2e' },
        card(T('Процессор, % · 24 ч'), cpuC, { icon: 'cpu' }), card(T('Память, % · 24 ч'), memC, { icon: 'mem' }),
        card(T('Температура, °C · 24 ч'), tC, { icon: 'thermo' }), card(T('Таблица соединений, % · 24 ч'), ctC, { icon: 'layers' })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2e' }, card(T('Диски'), disks, { icon: 'disk', flush: true }), card(T('Процессы: больше всего памяти'), procs, { icon: 'cpu', flush: true }))]);
    let h = null;
    const draw = () => {
      if (!h) return;
      const pts = h.history || [];
      const ser = (k) => pts.filter((p) => p[k] != null).map((p) => [p.t, p[k]]);
      const pf = (v) => Math.round(v) + '%';
      drawChart(cpuC, [{ name: 'CPU', color: '--chart-rx', fill: true, points: ser('cpu') }], { fmt: pf, max: 100, empty: T('История копится раз в минуту') });
      drawChart(memC, [{ name: T('Память'), color: '--chart-tx', fill: true, points: ser('mem') }], { fmt: pf, max: 100, empty: T('История копится раз в минуту') });
      drawChart(tC, [{ name: '°C', color: '--warn', fill: true, points: ser('temp') }], { fmt: (v) => Math.round(v) + '°C', empty: T('Датчики температуры не найдены') });
      drawChart(ctC, [{ name: 'conntrack', color: '--ok', fill: true, points: ser('ct') }], { fmt: pf, max: 100, empty: T('История копится раз в минуту') });
    };
    S.redraw = draw;
    async function load() {
      h = await api('/api/health');
      const dd = h.disks[0] || {};
      replace(gauges,
        gauge(h.cpu, T('Процессор'), T('нагрузка ') + h.load.map((x) => x.toFixed(2)).join(' ') + ' · ' + h.cores + T(' ядра'), toneOf(h.cpu, 80, 95)),
        gauge(h.mem.used_pct, T('Память'), T('свободно ') + fmtMB(h.mem.avail_mb) + T(' из ') + fmtMB(h.mem.total_mb), toneOf(h.mem.used_pct, 88, 95)),
        gauge(dd.used_pct || 0, T('Диск /data'), T('свободно ') + fmtMB(dd.free_mb), toneOf(dd.used_pct || 0, 85, 95)),
        h.temps.length ? gauge(Math.min(100, h.temp_max), T('Температура'), Math.round(h.temp_max) + '°C · ' + T('датчиков: ') + h.temps.length, toneOf(h.temp_max, 85, 95)) : null,
        h.conntrack.max > 0 ? gauge(100 * h.conntrack.count / h.conntrack.max, T('Соединения'), h.conntrack.count + T(' из ') + h.conntrack.max, toneOf(100 * h.conntrack.count / h.conntrack.max, 80, 95)) : null);
      replace(checks, h.checks.map(checkRow));
      const kv = (rows) => el('dl', { class: 'kv' }, rows.map(([k, v]) => [el('dt', null, k), el('dd', null, v)]));
      replace(info, kv([[T('Модель'), h.model], [T('Ядро'), h.kernel_ver], [T('Без перезагрузки'), fmtDur(h.uptime)], [T('Процессов'), String(h.nproc)],
        [T('Своп'), h.mem.swap_total_mb ? h.mem.swap_used_mb + ' / ' + h.mem.swap_total_mb + T(' МБ') : T('нет')],
        [T('OOM за сутки'), h.kernel.oom < 0 ? '—' : String(h.kernel.oom_sys == null ? h.kernel.oom : h.kernel.oom_sys) + (h.kernel.oom > (h.kernel.oom_sys == null ? h.kernel.oom : h.kernel.oom_sys) ? ' ' + T('(ещё в пределах лимита служб: ') + (h.kernel.oom - h.kernel.oom_sys) + ')' : '')], [T('Ошибки ввода-вывода за сутки'), h.kernel.io < 0 ? '—' : String(h.kernel.io)]].concat(
        h.temps.map((t) => [t.name, Math.round(t.c) + '°C']))));
      replace(disks, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Раздел')), el('th', { class: 'r' }, T('Свободно')), el('th', null, T('Занято')))),
        el('tbody', null, h.disks.map((d) => el('tr', null, el('td', null, el('span', { class: 'mono' }, d.path)), el('td', { class: 'r nowrap' }, fmtMB(d.free_mb)),
          el('td', null, el('div', { class: 'mbar ' + toneOf(d.used_pct, 85, 95) }, (() => { const i = el('i'); i.style.width = d.used_pct + '%'; return i; })()), el('span', { class: 'small muted' }, d.used_pct + '%')))))));
      replace(procs, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Процесс')), el('th', { class: 'r' }, 'PID'), el('th', { class: 'r' }, T('Память')))),
        el('tbody', null, h.procs.map((p) => el('tr', { title: p.cmd }, el('td', null, el('b', null, p.name), el('div', { class: 'small muted ell' }, p.cmd)), el('td', { class: 'r mono' }, p.pid), el('td', { class: 'r nowrap' }, p.rss_mb + T(' МБ')))))));
      draw();
    }
    every(15000, load);
  };

