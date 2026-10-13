  // ===================================================================== ЖУРНАЛЫ
  const LOGS = [['events', T('События')], ['failover', T('Сторож')], ['journal', 'systemd'], ['notify', T('Уведомления')], ['bot', T('Бот')], ['install', T('Установка')], ['update', T('Обновление')], ['restore', T('Восстановление')], ['audit', T('Действия в панели')]];
  PAGES.logs = function (main, sub) {
    const cur = LOGS.some((l) => l[0] === sub) ? sub : 'events';
    add(main, [head(T('Журналы')), tabs(LOGS, cur, (id) => { location.hash = '#/logs/' + id; })]);
    if (cur === 'events') return eventsPage(main);
    const box = el('pre', { class: 'logbox' }, T('загрузка…'));
    const auto = el('input', { type: 'checkbox', checked: true });
    const n = el('select', { class: 'input' }, ['200', '500', '1000', '3000'].map((x) => el('option', { value: x }, x + T(' строк'))));
    n.style.width = 'auto'; n.style.height = '30px';
    const filt = el('input', { class: 'input', placeholder: T('фильтр'), spellcheck: 'false' });
    filt.style.height = '30px'; filt.style.maxWidth = '220px';
    let text = '';
    const show = () => {
      const f = filt.value.trim().toLowerCase();
      const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
      box.textContent = (f ? text.split('\n').filter((l) => l.toLowerCase().includes(f)).join('\n') : text) || T('(пусто)');
      if (atBottom) box.scrollTop = box.scrollHeight;
    };
    const load = async () => { text = (await api('/api/logs?kind=' + cur + '&n=' + n.value)).text; show(); };
    filt.addEventListener('input', show);
    n.addEventListener('change', load);
    main.appendChild(el('section', { class: 'card' },
      el('div', { class: 'hd' }, el('h2', null, LOGS.find((l) => l[0] === cur)[1]), filt, n,
        el('label', { class: 'switch small' }, auto, el('span', { class: 'knob' }), T('авто')),
        el('a', { class: 'btn sm', href: '/api/logs/file?kind=' + cur, download: '' }, icon('download', 'sm'), T('Скачать')),
        el('button', { class: 'btn sm icon', 'aria-label': T('Обновить'), onclick: load }, icon('refresh', 'sm'))), box));
    load().then(() => { box.scrollTop = box.scrollHeight; }).catch(err);
    every(5000, async () => { if (auto.checked) await load(); }, false);
  };
  async function eventsPage(main) {
    const stats = el('div', { class: 'grid g-kpi' });
    const list = el('div');
    const types = el('select', { class: 'input' }, el('option', { value: '' }, T('все типы')), Object.entries(EVT).map(([k, v]) => el('option', { value: k }, v[2])));
    types.style.width = 'auto'; types.style.height = '30px';
    const q = el('input', { class: 'input', placeholder: T('поиск'), spellcheck: 'false' });
    q.style.height = '30px'; q.style.maxWidth = '220px';
    let evs = [];
    const show = () => {
      const f = q.value.trim().toLowerCase();
      const xs = evs.filter((e) => (!types.value || e.type === types.value) && (!f || e.text.toLowerCase().includes(f)));
      replace(list, xs.length ? xs.slice(0, 500).map(evRow) : el('div', { class: 'empty' }, T('Нет событий')));
    };
    types.addEventListener('change', show);
    q.addEventListener('input', show);
    add(main, [stats, el('div', { class: 'spacer' }),
      el('section', { class: 'card' }, el('div', { class: 'hd' }, el('h2', null, T('События сторожа')), q, types,
        el('a', { class: 'btn sm', href: '/api/logs/file?kind=events', download: '' }, icon('download', 'sm'), T('Скачать'))), list)]);
    const st = (lbl, v, sub) => el('div', { class: 'card kpi' }, el('div', { class: 'lbl' }, lbl), el('div', { class: 'val' }, v), el('div', { class: 'sub' }, sub));
    const load = async () => {
      const r = await api('/api/events?n=3000');
      evs = r.events;
      replace(stats,
        st(T('На основном · 7 дн'), r.stats7.on_main_pct + '%', T('вне основного ') + fmtDur(r.stats7.off_main_sec)),
        st(T('На основном · 30 дн'), r.stats30.on_main_pct + '%', T('вне основного ') + fmtDur(r.stats30.off_main_sec)),
        st(T('Переключений · 7 дн'), r.stats7.switch, T('по качеству: ') + r.stats7.degrade + T(', вручную: ') + r.stats7.force),
        st(T('Оба канала лежали · 7 дн'), r.stats7.both, T('запусков сторожа: ') + r.stats7.start));
      show();
    };
    every(10000, load);
  }

