  // ===================================================================== ТУННЕЛИ
  function upOk(p, t) {
    const x = p.tun && p.tun[t];
    if (!x) return null;
    // работает = свежий handshake; потери учитываем, только если их мерили по TCP (ICMP через туннель часто закрыт)
    return x.hs >= 0 && x.hs < 180 && !(x.qm === 'tcp' && String(x.loss) === '100');
  }
  function uptimeBar(points, t, buckets) {
    buckets = buckets || 48;
    const nowT = Math.floor(Date.now() / 1000), span = 86400, step = span / buckets;
    const bins = Array.from({ length: buckets }, () => [0, 0]);
    for (const p of points || []) {
      const i = Math.floor((p.t - (nowT - span)) / step);
      if (i < 0 || i >= buckets) continue;
      const o = upOk(p, t);
      if (o === null) continue;
      bins[i][1]++;
      if (o) bins[i][0]++;
    }
    let good = 0, all = 0;
    const bar = el('div', { class: 'ubar', role: 'img' });
    bins.forEach(([g, n], i) => {
      good += g; all += n;
      const r = n ? g / n : -1;
      const from = new Date((nowT - span + i * step) * 1000);
      bar.appendChild(el('i', { class: r < 0 ? '' : r >= 0.99 ? 'ok' : r >= 0.9 ? 'warn' : 'crit',
        title: pad2(from.getHours()) + ':' + pad2(from.getMinutes()) + ' — ' + (r < 0 ? T('нет данных') : Math.round(r * 1000) / 10 + T('% времени работал')) }));
    });
    const pct = all ? Math.round(good * 1000 / all) / 10 : null;
    bar.setAttribute('aria-label', T('Доступность за сутки: ') + (pct == null ? T('нет данных') : pct + '%'));
    return el('div', { class: 'uptime' }, el('div', { class: 'row between small muted' }, el('span', null, T('Доступность, 24 ч')), el('b', null, pct == null ? '—' : pct + '%')), bar);
  }
  function lineDiff(a, b) {
    const A = a.replace(/\n$/, '').split('\n'), B = b.replace(/\n$/, '').split('\n');
    const n = A.length, m = B.length, L = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = A[i] === B[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
    const out = [];
    let i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && A[i] === B[j]) { out.push([' ', A[i]]); i++; j++; }
      else if (j < m && (i >= n || L[i][j + 1] >= L[i + 1][j])) { out.push(['+', B[j]]); j++; }
      else { out.push(['-', A[i]]); i++; }
    }
    return out;
  }
  function diffView(a, b) {
    const d = lineDiff(a, b);
    if (!d.some((x) => x[0] !== ' ')) return el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Изменений нет.')));
    return el('pre', { class: 'diff' }, d.map(([k, l]) => el('span', { class: k === '+' ? 'add' : k === '-' ? 'del' : '' }, (k === ' ' ? '  ' : k + ' ') + l + '\n')));
  }
  function dropZone(onText, hint) {
    const f = el('input', { type: 'file', accept: '.conf,.txt,.json,.vpn,text/plain,application/json', class: 'hidden' });
    const read = (file) => {
      if (!file) return;
      if (file.size > 200000) { err(T('файл слишком большой')); return; }
      const rd = new FileReader();
      rd.onload = () => onText(String(rd.result), file.name);
      rd.readAsText(file);
    };
    f.addEventListener('change', () => read(f.files[0]));
    const z = el('div', { class: 'drop', tabindex: 0, role: 'button', onclick: () => f.click() },
      icon('upload', 'lg'), el('b', null, T('Перетащите файл сюда или нажмите')), el('span', { class: 'small muted' }, hint || T('.conf из AmneziaVPN, панели сервера или провайдера')), f);
    z.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); f.click(); } });
    z.addEventListener('dragover', (e) => { e.preventDefault(); z.classList.add('over'); });
    z.addEventListener('dragleave', () => z.classList.remove('over'));
    z.addEventListener('drop', (e) => { e.preventDefault(); z.classList.remove('over'); read(e.dataTransfer.files[0]); });
    return z;
  }
  function closeTop() { const m = document.querySelectorAll('.modal-bg'); if (m.length) m[m.length - 1].remove(); }

  PAGES.tunnels = function (main) {
    const autoBtn = el('button', { class: 'btn hidden', onclick: async () => { try { ok((await api('/api/tunnel/auto', {})).msg); load(); } catch (e) { err(e); } } }, icon('refresh'), T('Автовыбор канала'));
    const grid = el('div', { class: 'grid g-tun' });
    const alerts = el('div');
    add(main, [head(T('Туннели'), autoBtn,
      el('button', { class: 'btn', onclick: () => importDialog(load) }, icon('upload'), T('Импорт')),
      el('button', { class: 'btn primary', onclick: () => importDialog(load, 'new') }, icon('plus'), T('Добавить'))), alerts, el('div', { class: 'spacer' }), grid]);
    const cards = {};
    async function load() {
      const ov = await api('/api/overview');
      S.ov = ov;
      updateChrome(ov);
      autoBtn.classList.toggle('hidden', !ov.forced);
      replace(alerts, ov.forced ? el('div', { class: 'alert warn' }, icon('info'), el('div', null, T('Канал выбран вручную: '), el('b', null, ov.forced), T('. Сторож не переключит его, пока он работает. Чтобы вернуть автоматику — «Автовыбор канала».'))) : null);
      const names = ov.tunnels.map((t) => t.name);
      for (const k of Object.keys(cards)) if (!names.includes(k)) { cards[k].remove(); delete cards[k]; }
      const extras = ov.tunnels.filter((t) => t.role === 'extra').map((t) => t.name);
      for (const t of ov.tunnels) {
        const c = tunnelCard(t, ov, load, extras);
        if (cards[t.name]) cards[t.name].replaceWith(c); else grid.appendChild(c);
        cards[t.name] = c;
      }
      for (const t of ov.tunnels) grid.appendChild(cards[t.name]);
      let addc = grid.querySelector('.tun.add');
      if (!addc) addc = el('button', { class: 'card tun add', onclick: () => importDialog(load, 'new') }, el('div', { class: 'stack' }, icon('plus', 'lg'), T('Добавить туннель'), el('span', { class: 'small' }, T('Файл .conf, ссылка vpn:// или текст: сторож будет переключаться и на него'))));
      grid.appendChild(addc);
    }
    every(5000, load);
    every(60000, async () => { S.hist = (await api('/api/history')).points; for (const [t, c] of Object.entries(cards)) { const u = c.querySelector('.uptime'); if (u) u.replaceWith(uptimeBar(S.hist, t)); } });
    every(2000, async () => {
      S.live = (await api('/api/live')).live;
      for (const [t, c] of Object.entries(cards)) {
        const sp = c.querySelector('.spark'), rt = c.querySelector('.rates');
        if (sp) replace(sp, sparkline(S.live[t]));
        const r = lastRate(t);
        if (rt) replace(rt, el('span', null, '↓ ', el('b', null, r ? fmtBits(r[1]) : '—')), el('span', null, '↑ ', el('b', null, r ? fmtBits(r[2]) : '—')));
      }
    });
  };
  function tunnelCard(t, ov, reload, extras) {
    const [host, port] = splitEndpoint(t.endpoint);
    const st = STATUS[t.status];
    const kv = el('dl', { class: 'kv' },
      el('dt', null, T('Сервер')), el('dd', null, host ? secret('ep-' + t.name, host) : '—'),
      el('dt', null, T('Порт')), el('dd', null, el('span', { class: 'mono' }, port || '—')),
      el('dt', null, T('Адрес туннеля')), el('dd', null, el('span', { class: 'mono' }, (t.address || '—').split(',')[0])),
      el('dt', null, 'Handshake'), el('dd', null, t.handshake >= 0 ? fmtAge(t.handshake) : el('span', { class: 'badge warn' }, T('нет'))),
      el('dt', null, T('Качество')), el('dd', null, qText(t)),
      el('dt', null, T('DNS через туннель')), el('dd', null, t.dns === '' ? '—' : t.dns === '1' || t.dns === 'ok' ? el('span', { class: 'badge ok' }, T('работает')) : el('span', { class: 'badge warn' }, T('нет ответа'))),
      el('dt', null, 'MTU'), el('dd', null, t.mtu || '—'),
      el('dt', null, T('Всего ↓ / ↑')), el('dd', null, fmtBytes(t.rx) + ' / ' + fmtBytes(t.tx)),
      el('dt', null, T('Конфиг')), el('dd', null, el('span', { class: 'mono' }, t.conf), t.conf_mode && t.conf_mode !== '600' ? el('span', { class: 'badge warn', title: T('Права на файл с ключом') }, t.conf_mode) : null));
    const r = lastRate(t.name);
    const act = el('button', { class: 'btn sm' + (t.active ? '' : ' primary'), disabled: t.active || t.status === 'down' },
      icon(t.active ? 'check' : 'switch', 'sm'), t.active ? T('Активен') : T('Активировать'));
    act.addEventListener('click', () => busy(act, async () => {
      try { const x = await api('/api/tunnel/switch', { name: t.name }); (x.ok ? ok : err)(x.msg); reload(); } catch (e) { err(e); }
    }));
    const xi = extras.indexOf(t.name);
    const more = [
      el('button', { class: 'btn sm icon', title: T('Тест канала'), 'aria-label': T('Тест'), onclick: () => tunnelTest(t) }, icon('stetho', 'sm')),
      el('button', { class: 'btn sm icon', title: T('Перезапустить туннель'), 'aria-label': T('Перезапустить'), onclick: async () => {
        if (!await confirmBox(T('Перезапустить ') + t.name + '?', t.active ? T('Это активный канал: на несколько секунд трафик PBR остановится (kill switch не даст ему уйти мимо).') : T('Интерфейс будет пересоздан с текущим конфигом.'), T('Перезапустить'))) return;
        try { const x = await api('/api/tunnel/restart', { name: t.name }); (x.ok ? ok : err)(x.msg || T('готово')); reload(); } catch (ex) { err(ex); }
      } }, icon('refresh', 'sm')),
    ];
    const lbl = el('button', { class: 'btn ghost icon sm', title: T('Название'), 'aria-label': T('Переименовать'), onclick: () => tunnelLabel(t, reload) }, icon('edit', 'sm'));
    return el('section', { class: 'card tun' + (t.active ? ' active' : '') },
      el('div', { class: 'hd' },
        el('div', { class: 'title' }, el('div', { class: 'nm' }, el('span', { class: 'dot ' + dotFor(t.status) }), t.label || t.name, lbl),
          el('div', { class: 'lb' }, t.label ? t.name + ' · ' : '', ROLE[t.role], t.role === 'extra' ? ' №' + (xi + 1) : '')),
        el('div', { class: 'badges' }, el('span', { class: 'badge accent' }, t.proto), el('span', { class: 'badge ' + st[0] }, st[1]), t.forced ? el('span', { class: 'badge warn' }, T('вручную')) : null)),
      el('div', { class: 'bd' }, kv),
      el('div', { class: 'rates' }, el('span', null, '↓ ', el('b', null, r ? fmtBits(r[1]) : '—')), el('span', null, '↑ ', el('b', null, r ? fmtBits(r[2]) : '—'))),
      el('div', { class: 'spark' }, sparkline(S.live[t.name])),
      el('div', { class: 'upw' }, uptimeBar(S.hist, t.name)),
      el('div', { class: 'ft' }, act, el('button', { class: 'btn sm', onclick: () => tunnelEditor(t, reload) }, icon('settings', 'sm'), T('Настроить')), el('span', { class: 'push' }), more));
  }
  function tunnelLabel(t, reload) {
    const inp = el('input', { class: 'input', value: t.label, maxlength: 40, placeholder: T('например: Германия, Hetzner') });
    const save = async () => { try { await api('/api/tunnel/label', { name: t.name, label: inp.value }); m.close(); reload(); } catch (e) { err(e); } };
    inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') save(); });
    const m = modal(T('Название ') + t.name, el('div', { class: 'field' }, el('label', null, T('Название (видно только в панели)')), inp),
      [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), el('button', { class: 'btn primary', onclick: save }, T('Сохранить'))]);
  }
  function tunnelTest(t) {
    const body = el('div', null, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), T('Проверяю ') + t.name + T(': HTTPS к трём адресам, DNS через туннель, внешний IP, MTU… (до 30 с)')));
    modal(T('Тест ') + (t.label || t.name), body, []);
    api('/api/tunnel/test', { name: t.name }).then((r) => {
      const it = (name, good, val) => el('div', { class: 'it' }, el('span', { class: 'dot ' + (good ? 'ok' : 'crit') }), name, el('span', { class: 'v' }, val));
      replace(body,
        el('div', { class: 'alert ' + (r.ok ? 'ok' : 'crit') }, icon(r.ok ? 'okc' : 'alert'), el('div', null, r.ok ? T('Канал работает') : T('Канал не пропускает трафик'))),
        el('div', { class: 'spacer' }),
        el('div', { class: 'test-list' },
          it('Handshake', r.handshake >= 0 && r.handshake < 180, r.handshake >= 0 ? fmtAge(r.handshake) : T('нет')),
          r.https.map((h) => it('HTTPS ' + h.target, h.ok, h.ok ? h.ms + T(' мс') : T('нет ответа'))),
          it(T('DNS через туннель (DoH)'), r.dns, r.dns ? T('работает') : T('нет')),
          it(T('Внешний IP'), !!r.ip, r.ip ? secret('tip-' + t.name, r.ip) : T('не получен')),
          r.mtu ? it('MTU ' + (t.mtu || ''), r.mtu === 'ok', r.mtu === 'ok' ? T('проходит') : T('пакеты не проходят — подберите MTU')) : null));
    }).catch((e) => replace(body, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))));
  }

  // ---------- редактор туннеля: параметры, текст, история, качество, экспорт
  const FGROUPS = [
    [T('Сервер'), [['Peer', 'Endpoint'], ['Peer', 'AllowedIPs'], ['Peer', 'PersistentKeepalive']]],
    [T('Интерфейс'), [['Interface', 'Address'], ['Interface', 'MTU'], ['Interface', 'DNS']]],
    [T('Ключи'), [['Interface', 'PrivateKey'], ['Peer', 'PublicKey'], ['Peer', 'PresharedKey']]],
    [T('Обфускация AmneziaWG'), [['Interface', 'Jc'], ['Interface', 'Jmin'], ['Interface', 'Jmax'], ['Interface', 'S1'], ['Interface', 'S2'], ['Interface', 'H1'], ['Interface', 'H2'], ['Interface', 'H3'], ['Interface', 'H4']]],
    ['AmneziaWG 2.0', [['Interface', 'S3'], ['Interface', 'S4'], ['Interface', 'I1'], ['Interface', 'I2'], ['Interface', 'I3'], ['Interface', 'I4'], ['Interface', 'I5']]],
    ['AmneziaWG 3.x', [['Interface', 'HeaderProtectionKey'], ['Interface', 'ContentPaddingAddition'], ['Interface', 'RekeyAfterTime'], ['Interface', 'RekeyTimeout'], ['Interface', 'RejectAfterTime'], ['Interface', 'KeepaliveTimeout'], ['Interface', 'MaxHandshakeAttempts'], ['Interface', 'RandomTrailers'], ['Interface', 'DisableCookies']]],
  ];
  const MASKV = '<скрыто>';
  async function tunnelEditor(t, reload, start) {
    let d;
    try { d = await api('/api/tunnel/fields?name=' + encodeURIComponent(t.name)); } catch (e) { err(e); return; }
    const body = el('div');
    const foot = el('div', { class: 'row wrap grow' });
    let cur = start || 'form';
    const tb = el('div', { class: 'tabs' });
    const TABS = [['form', T('Параметры')], ['text', T('Текст конфига')], ['hist', T('История (') + d.revisions + ')'], ['quality', T('Качество')], ['export', T('Ещё')]];
    const m = modal((t.label || t.name) + T(' · настройка'), el('div', null, tb, body), [foot], { wide: true, sticky: true });
    const show = (k) => {
      cur = k;
      replace(tb, TABS.map(([id, name]) => el('button', { class: 'tab' + (id === cur ? ' on' : ''), onclick: () => show(id) }, name)));
      clear(body); clear(foot);
      ({ form: edForm, text: edText, hist: edHist, quality: edQuality, export: edExport })[k]();
    };
    // число версий в названии вкладки: после применения, возврата или импорта история растёт
    const setHist = (n) => {
      TABS[2][1] = T('История (') + n + ')';
      replace(tb, TABS.map(([id, name]) => el('button', { class: 'tab' + (id === cur ? ' on' : ''), onclick: () => show(id) }, name)));
    };
    const res = el('div', { class: 'res hidden' });
    async function applyFlow(payload, btn) {
      await busy(btn, async () => {
        let p;
        try { p = await api('/api/tunnel/preview', Object.assign({ name: t.name }, payload)); } catch (e) { err(e); return; }
        if (p.errors.length) {
          replace(res, T('Не принято:\n• ') + p.errors.join('\n• ')); res.classList.remove('hidden'); res.classList.add('bad');
          res.scrollIntoView({ block: 'nearest', behavior: 'smooth' });   // форма длинная: без прокрутки ошибку внизу не видно
          err(T('Не принято: ') + p.errors.length + T(' — подробности под формой'));
          return;
        }
        if (!p.changed) { toast(T('Изменений нет')); return; }
        const go = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Применить'));
        const cm = modal(T('Проверьте изменения · ') + t.name, el('div', null,
          el('p', { class: 'muted small' }, T('Туннель будет пересоздан с новым конфигом (несколько секунд без трафика через него). Если он не поднимется — вернётся прежний конфиг. Прежняя версия сохранится в истории.')),
          diffView(p.old, p.new)), [el('button', { class: 'btn', onclick: () => cm.close() }, T('Отмена')), go], { wide: true });
        go.addEventListener('click', () => busy(go, async () => {
          try {
            const x = await api('/api/tunnel/conf', Object.assign({ name: t.name }, payload));
            cm.close();
            replace(res, x.msg); res.classList.remove('hidden', 'bad');
            (x.ok ? ok : err)(x.ok ? T('Конфиг применён') : T('Конфиг не применён: возвращён прежний'));
            reload();
            d = await api('/api/tunnel/fields?name=' + encodeURIComponent(t.name));
            setHist(d.revisions);
          } catch (e) { err(e); }
        }));
      });
    }
    function edForm() {
      const sch = {};
      d.schema.forEach((x) => { sch[x.sec + '.' + x.key] = x; });
      const ctl = {};
      const groups = FGROUPS.map(([title, keys]) => {
        const has2 = keys.some(([s, k]) => (d.fields[s] || {})[k]);
        const rows = keys.map(([s, k]) => {
          const x = sch[s + '.' + k] || { hint: '' };
          const v = (d.fields[s] || {})[k] || '';
          let inp;
          if (x.secret) {
            inp = el('input', { class: 'input mono', type: 'password', autocomplete: 'off', spellcheck: 'false', placeholder: v ? T('задан — не показывается') : T('не задан') });
            ctl[s + '.' + k] = () => (inp.value.trim() ? inp.value.trim() : (v ? MASKV : ''));
          } else if (/^I[1-5]$/.test(k)) {
            inp = el('textarea', { class: 'input mono', rows: 2, spellcheck: 'false' }); inp.value = v;
            ctl[s + '.' + k] = () => inp.value.trim();
          } else {
            inp = el('input', { class: 'input mono', value: v, spellcheck: 'false', autocomplete: 'off', inputmode: /^(Jc|Jmin|Jmax|S\d|MTU|PersistentKeepalive)$/.test(k) ? 'numeric' : 'text' });
            ctl[s + '.' + k] = () => inp.value.trim();
          }
          ctl[s + '.' + k].orig = x.secret ? (v ? MASKV : '') : v;
          return el('div', { class: 'field' }, el('label', null, k, x.req ? el('span', { class: 'req' }, ' *') : null), inp, x.hint ? el('span', { class: 'hint' }, x.hint) : null);
        });
        const g = el('div', { class: 'form-grid' }, rows);
        if (title === 'AmneziaWG 2.0' || title === 'AmneziaWG 3.x' || title === T('Ключи')) {
          return el('details', { class: 'fgroup', open: title !== T('Ключи') ? has2 : false }, el('summary', null, title, title === T('Ключи') ? el('span', { class: 'muted small' }, T(' — менять только при смене сервера или ключей')) : null), g);
        }
        return el('div', { class: 'fgroup' }, el('h3', null, title), g);
      });
      add(body, [
        d.peers > 1 ? el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('В конфиге несколько [Peer]: форма меняет только первый. Остальные — во вкладке «Текст конфига».'))) : null,
        d.other.length ? el('div', { class: 'small muted' }, T('Другие строки конфига сохраняются как есть: ') + d.other.join(', ')) : null,
        groups, res]);
      const chk = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Проверить и применить'));
      chk.addEventListener('click', () => {
        const f = { Interface: {}, Peer: {} };
        for (const [key, g] of Object.entries(ctl)) {
          const val = g();
          if (val !== g.orig) { const [s, k] = key.split('.'); f[s][k] = val; }
        }
        if (!Object.keys(f.Interface).length && !Object.keys(f.Peer).length) { toast(T('Изменений нет')); return; }
        applyFlow({ fields: f }, chk);
      });
      add(foot, [el('span', { class: 'small muted grow' }, T('Файл: ') + d.path), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть')), chk]);
    }
    function edText() {
      const ta = el('textarea', { class: 'input tall', spellcheck: 'false', autocomplete: 'off' });
      ta.value = d.text;
      add(body, [
        el('div', { class: 'alert info' }, icon('lock'), el('div', null, T('Ключи заменены на «'), el('code', null, MASKV), T('» — такие строки сохранят прежнее значение. Новый конфиг можно вставить целиком или перетащить файл. Строки PostUp/PreDown не допускаются.'))),
        el('div', { class: 'spacer' }), dropZone((txt) => { ta.value = txt; toast(T('Файл загружен: проверьте и примените')); }, T('Заменить конфиг этого туннеля файлом .conf')),
        el('div', { class: 'spacer' }), ta, res]);
      const chk = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Проверить и применить'));
      chk.addEventListener('click', () => {
        if (/^\s*vpn:\/\//.test(ta.value)) { m.close(); importDialog(reload, t.name, ta.value); return; }
        applyFlow({ text: ta.value }, chk);
      });
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть')), chk]);
    }
    async function edHist() {
      const box = el('div', null, el('div', { class: 'row' }, el('span', { class: 'spinner sm' }), T('загрузка…')));
      add(body, [el('p', { class: 'muted small' }, T('Каждое изменение конфига сохраняется (до 15 версий, права 600). Можно сравнить с текущим и вернуть.')), box]);
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть'))]);
      try {
        const r = await api('/api/tunnel/revisions?name=' + encodeURIComponent(t.name));
        setHist(r.revisions.length);
        replace(box, r.revisions.length ? el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
          el('thead', null, el('tr', null, el('th', null, T('Версия')), el('th', null, T('Что')), el('th', null, T('Сервер')), el('th', null, ''), el('th', null, ''))),
          el('tbody', null, r.revisions.map((v) => el('tr', null,
            el('td', { class: 'nowrap' }, fmtTime(v.time, true), v.current ? el('span', { class: 'badge ok' }, T('текущая')) : v.same ? el('span', { class: 'badge outline' }, T('как текущая')) : null),
            el('td', { class: 'muted' }, v.why || '—'),
            el('td', null, el('span', { class: 'mono small' }, v.summary.endpoint || '—'), ' ', el('span', { class: 'badge outline' }, v.summary.proto)),
            el('td', { class: 'r nowrap' }, el('button', { class: 'btn sm', onclick: async () => {
              try { const x = await api('/api/tunnel/revision?name=' + encodeURIComponent(t.name) + '&id=' + encodeURIComponent(v.id)); modal(T('Версия ') + fmtTime(v.time, true) + T(' → текущая'), diffView(x.text, x.current), [], { wide: true }); } catch (e) { err(e); }
            } }, T('Сравнить'))),
            el('td', { class: 'r nowrap' }, v.current || v.same ? null : el('button', { class: 'btn sm primary', onclick: async (e) => {
              if (!await confirmBox(T('Вернуть версию?'), T('Конфиг ') + t.name + T(' станет таким, как ') + fmtTime(v.time, true) + T('. Текущий сохранится в истории.'), T('Вернуть'))) return;
              try { const x = await api('/api/tunnel/revision/restore', { name: t.name, id: v.id }); (x.ok ? ok : err)(x.msg.split('\n')[0]); reload(); show('hist'); } catch (ex) { err(ex); }
            } }, T('Вернуть')))))))) : el('div', { class: 'empty' }, T('Версий пока нет: они появятся после первого изменения.')));
      } catch (e) { replace(box, e.message); }
    }
    async function edQuality() {
      const rtt = el('div', { class: 'chart-wrap sm' }), loss = el('div', { class: 'chart-wrap sm' });
      const sp = el('div');
      const spOut = el('div', { class: 'out hidden' });
      const size = el('select', { class: 'input' }, [5, 10, 25, 50].map((x) => el('option', { value: x, selected: x === 10 }, x + T(' МБ'))));
      size.style.width = 'auto';
      const run = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Замерить скорость'));
      add(body, [uptimeBar(S.hist, t.name), el('div', { class: 'spacer' }),
        el('div', { class: 'grid g-2e' }, el('div', null, el('h3', null, T('Задержка (RTT), мс')), rtt), el('div', null, el('h3', null, T('Потери, %')), loss)),
        el('div', { class: 'spacer' }), el('h3', null, T('Замеры скорости')), el('p', { class: 'small muted' }, T('Скачивание и отдача через этот туннель (speed.cloudflare.com). Трафик замера считается у провайдера VPN.')),
        el('div', { class: 'row' }, size, run), spOut, sp]);
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть'))]);
      const loadSp = async () => {
        const r = await api('/api/speed');
        const xs = r.history.filter((x) => x.iface === t.name).slice(0, 10);
        replace(sp, xs.length ? el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Когда')), el('th', null, T('Загрузка')), el('th', null, T('Отдача')), el('th', null, T('Задержка')))),
          el('tbody', null, xs.map((x) => el('tr', null, el('td', null, fmtTime(x.t, true)), el('td', null, x.down_bps ? fmtBits(x.down_bps) : '—'), el('td', null, x.up_bps ? fmtBits(x.up_bps) : '—'), el('td', null, x.ping_ms ? x.ping_ms + T(' мс') : '—'))))) : el('div', { class: 'empty' }, T('Замеров ещё не было')));
      };
      run.addEventListener('click', () => busy(run, async () => {
        spOut.classList.remove('hidden'); spOut.textContent = '';
        try { await runJob({ tool: 'speedtest', iface: t.name, mb: +size.value }, spOut); await loadSp(); } catch (e) { err(e); }
      }));
      try {
        if (!S.hist) S.hist = (await api('/api/history')).points;
        const pts = S.hist.filter((p) => p.tun && p.tun[t.name]);
        drawChart(rtt, [{ name: 'RTT', color: '--chart-rx', fill: true, points: pts.filter((p) => p.tun[t.name].rtt !== '').map((p) => [p.t, +p.tun[t.name].rtt]) }],
          { fmt: (v) => Math.round(v) + T(' мс'), empty: T('Нет данных: RTT меряется, когда включено переключение по качеству') });
        drawChart(loss, [{ name: T('Потери'), color: '--crit', fill: true, points: pts.filter((p) => p.tun[t.name].loss !== '').map((p) => [p.t, +p.tun[t.name].loss]) }],
          { fmt: (v) => Math.round(v) + '%', max: 100, empty: T('Нет данных') });
        await loadSp();
      } catch (e) { err(e); }
    }
    function edExport() {
      const pw = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const go = el('button', { class: 'btn primary' }, icon('download', 'sm'), T('Скачать ') + t.name + '.conf');
      go.addEventListener('click', () => busy(go, async () => {
        try {
          const x = await api('/api/tunnel/export', { name: t.name, current: pw.value });
          const a = el('a', { href: URL.createObjectURL(new Blob([x.text], { type: 'text/plain' })), download: x.filename });
          document.body.appendChild(a); a.click(); a.remove(); pw.value = '';
          ok(T('Файл скачан: храните его как пароль'));
        } catch (e) { err(e); }
      }));
      const extras = (S.ov ? S.ov.tunnels : []).filter((x) => x.role === 'extra').map((x) => x.name);
      const xi = extras.indexOf(t.name);
      const move = (dir) => async () => {
        const n = extras.slice(); n.splice(xi + dir, 0, n.splice(xi, 1)[0]);
        try { ok((await api('/api/tunnel/order', { extra: n })).msg); m.close(); reload(); } catch (ex) { err(ex); }
      };
      add(body, [
        el('h3', null, T('Скачать конфиг')),
        el('div', { class: 'alert warn' }, icon('key'), el('div', null, T('Файл содержит закрытый ключ роутера. Не отправляйте его в чаты. Одновременно использовать этот же конфиг на другом устройстве нельзя: сервер будет «перекидывать» сеанс между ними.'))),
        el('div', { class: 'spacer' }), el('div', { class: 'input-group' }, el('div', { class: 'field grow' }, el('label', null, T('Ваш пароль от панели')), pw)), go,
        xi >= 0 ? [el('div', { class: 'spacer' }), el('h3', null, T('Приоритет')), el('p', { class: 'muted small' }, T('Порядок: основной → запасной → дополнительные. Сейчас этот туннель №') + (xi + 1) + T(' из ') + extras.length + T(' дополнительных.')),
          el('div', { class: 'row' }, el('button', { class: 'btn', disabled: xi === 0, onclick: move(-1) }, icon('up', 'sm'), T('Выше')),
            el('button', { class: 'btn', disabled: xi === extras.length - 1, onclick: move(1) }, T('Ниже')))] : null,
        t.role === 'extra' ? [el('div', { class: 'spacer' }), el('h3', null, T('Удалить туннель')),
          el('p', { class: 'muted small' }, T('Туннель будет остановлен и убран из сторожа вместе с его правилами. Файл конфига и история версий останутся на роутере.')),
          el('button', { class: 'btn danger', onclick: async () => {
            const pw = await promptPw(T('Удалить ') + t.name + '?', T('Туннель будет остановлен и убран из сторожа.'));
            if (pw == null) return;
            try { ok((await api('/api/tunnel/remove', { name: t.name, current: pw })).msg); m.close(); reload(); } catch (ex) { err(ex); }
          } }, icon('trash', 'sm'), T('Удалить ') + t.name)]
          : el('p', { class: 'small muted' }, T('Основной и запасной туннели удаляются установщиком: install.sh → Компоненты → Туннели.'))]);
      add(foot, [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть'))]);
    }
    show(cur);
  }

  // ---------- импорт: файл, текст, ссылка vpn://
  function importDialog(reload, target, preset) {
    const ta = el('textarea', { class: 'input', rows: 7, spellcheck: 'false', placeholder: T('[Interface]\nPrivateKey = …\n…\n\nили ссылка vpn://… из AmneziaVPN («Поделиться» → «Ключ»)') });
    if (preset) ta.value = preset;
    let fname = '';
    const res = el('div');
    const parse = el('button', { class: 'btn primary' }, icon('search', 'sm'), T('Разобрать'));
    const foot = [el('span', { class: 'grow' }), el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть')), parse];
    const m = modal(target === 'new' ? T('Новый туннель') : T('Импорт конфига'), el('div', null,
      dropZone((txt, n) => { ta.value = txt; fname = n; parse.click(); }),
      el('div', { class: 'spacer' }), el('div', { class: 'field' }, el('label', null, T('Или вставьте текст конфига или ссылку vpn://')), ta), res), foot, { wide: true, sticky: true });
    parse.addEventListener('click', () => busy(parse, async () => {
      let r;
      try { r = await api('/api/import/parse', { data: ta.value }); } catch (e) { replace(res, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, e.message))); return; }
      const f = r.fields;
      const info = el('dl', { class: 'kv' },
        el('dt', null, T('Источник')), el('dd', null, r.source === 'vpn://' ? T('ссылка AmneziaVPN') : r.source === 'json' ? 'JSON AmneziaVPN' : (fname || T('текст конфига'))),
        el('dt', null, T('Протокол')), el('dd', null, el('span', { class: 'badge accent' }, r.proto)),
        el('dt', null, T('Сервер')), el('dd', null, el('span', { class: 'mono' }, f.Peer.Endpoint || '—')),
        el('dt', null, T('Адрес')), el('dd', null, el('span', { class: 'mono' }, f.Interface.Address || '—')),
        el('dt', null, 'MTU'), el('dd', null, f.Interface.MTU || T('по умолчанию')));
      const used = S.ov ? S.ov.tunnels : [];
      let sug = 'awgalt1';
      for (let i = 1; used.some((t) => t.name === sug); i++) sug = 'awgalt' + (i + 1);
      const nm = el('input', { class: 'input mono', value: sug, maxlength: 13, autocapitalize: 'off', spellcheck: 'false' });
      const lb = el('input', { class: 'input', maxlength: 40, placeholder: T('например: Нидерланды') });
      const tsel = el('select', { class: 'input' }, el('option', { value: 'new' }, T('Новый дополнительный туннель')),
        used.map((t) => el('option', { value: t.name, selected: target === t.name }, T('Заменить конфиг: ') + (t.label ? t.label + ' (' + t.name + ')' : t.name) + ' — ' + ROLE[t.role].toLowerCase())));
      const newBox = el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Имя интерфейса')), nm, el('span', { class: 'hint' }, T('awg + до 10 латинских букв/цифр'))),
        el('div', { class: 'field' }, el('label', null, T('Название')), lb));
      const sync = () => newBox.classList.toggle('hidden', tsel.value !== 'new');
      tsel.addEventListener('change', sync); sync();
      const out = el('div', { class: 'res hidden' });
      const apply = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Применить'));
      apply.addEventListener('click', () => busy(apply, async () => {
        if (tsel.value !== 'new' && !await confirmBox(T('Заменить конфиг ') + tsel.value + '?', T('Туннель будет пересоздан с новым конфигом. Прежний сохранится в истории версий; если новый не поднимется — вернётся прежний.'), T('Заменить'))) return;
        try {
          const x = await api('/api/import/apply', { token: r.token, target: tsel.value, name: nm.value.trim(), label: lb.value.trim() });
          out.textContent = x.msg; out.classList.remove('hidden');
          (x.ok ? ok : err)(x.ok ? T('Готово') : T('Применено с ошибкой — смотрите вывод'));
          reload();
        } catch (e) { out.textContent = e.message; out.classList.remove('hidden'); err(e); }
      }));
      replace(res, el('div', { class: 'spacer' }),
        r.errors.length ? el('div', { class: 'alert crit' }, icon('alert'), el('div', null, T('Конфиг не подходит:'), el('ul', null, r.errors.map((x) => el('li', null, x))))) : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, T('Конфиг распознан. Ключи остаются на роутере и в браузер не возвращаются.'))),
        r.warnings.length ? el('div', { class: 'alert warn' }, icon('info'), el('div', null, r.warnings.join('; '))) : null,
        el('div', { class: 'spacer' }), info,
        r.ok ? [el('div', { class: 'spacer' }), el('div', { class: 'field' }, el('label', null, T('Куда')), tsel), newBox, out] : null);
      const ft = m.root.querySelector('.ft');
      if (r.ok) { parse.classList.remove('primary'); if (!ft.contains(apply)) ft.appendChild(apply); } else { apply.remove(); parse.classList.add('primary'); }
    }));
    if (preset) parse.click();
  }
  async function runJob(payload, pre) {
    const j = await api('/api/tool', payload);
    let off = 0, text = '';
    for (;;) {
      const r = await api('/api/job?id=' + j.job + '&from=' + off);
      off = r.len;
      if (r.out) { text += r.out; if (pre) { paint(pre, text); pre.scrollTop = pre.scrollHeight; } }
      if (r.done) return { rc: r.rc, text };
      await new Promise((ok2) => setTimeout(ok2, 1000));
    }
  }

