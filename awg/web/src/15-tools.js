  // ===================================================================== ИНСТРУМЕНТЫ
  const TOOLS = [
    ['diagnose', T('Диагностика'), 'stetho', T('Дерево причин: WAN → туннели → PBR → NAT → IPv6 → службы. Итог — первая причина и команда исправления.')],
    ['selftest', T('Самопроверка'), 'okc', T('Проверка установки: файлы, службы, правила, маршруты, handshake.')],
    ['selftest-full', T('Проверка kill switch'), 'shield', T('Самопроверка с кратким отключением туннелей: трафик PBR не должен уйти в WAN.')],
    ['switch-test', T('Тест переключения'), 'switch', T('Имитация падения основного канала: сторож должен уйти на запасной (до 45 с).')],
    ['audit', T('Аудит'), 'search', T('Права на файлы, ключи, открытые порты, лишние правила.')],
    ['dedup', T('Очистка дубликатов'), 'layers', T('Убрать повторяющиеся правила iptables, если они накопились.')],
    ['mtu', T('Подбор MTU'), 'ruler', T('Найти наибольший MTU, который проходит через каждый туннель.')],
    ['guard-check', T('Проверка защиты'), 'shield', T('Правила защиты от утечек, наборы доменов и исключений.')],
    ['self-check', T('Трафик роутера'), 'router', T('Проверка awg-self: unifi.ui.com и DNS самого роутера.')],
    ['subnets-check', T('Подсети VPN'), 'users', T('Правила для клиентов VPN-сервера роутера.')],
    ['self-reconnect', T('Переподключить облако'), 'refresh', T('Сбросить соединения роутера с облаком UniFi, чтобы они пошли новым путём.')],
    ['report', T('Отчёт для помощи'), 'file', T('Обезличенный отчёт (ключи, токены и IP скрыты) — приложить к issue на GitHub.')],
  ];
  PAGES.tools = function (main) {
    const out = el('div', { class: 'out', 'aria-live': 'polite' }, el('div', { class: 'empty' }, T('Выберите инструмент — вывод появится здесь.')));
    const status = el('span', { class: 'muted small' });
    const dl = el('span');
    let lastTool = 'awg';
    const outCard = el('section', { class: 'card' }, el('div', { class: 'hd' }, icon('logs'), el('h2', null, T('Вывод')), dl, status, outTools(out, () => 'awg-' + lastTool)), out);
    let polling = null;
    async function runTool(payload, title) {
      if (polling) clearInterval(polling);
      replace(dl);
      clear(out); out.dataset.raw = '';
      lastTool = (payload.tool || payload.kind || 'tool').replace(/[^a-z0-9-]/gi, '');
      replace(status, el('span', { class: 'row' }, el('span', { class: 'spinner sm' }), title + '…'));
      outCard.scrollIntoView({ behavior: 'smooth', block: 'start' });
      let j;
      try { j = await api(payload.ep || '/api/tool', payload); } catch (e) { replace(status, ''); out.textContent = e.message; return; }
      let off = 0, text = '';
      const poll = async () => {
        try {
          const r = await api('/api/job?id=' + j.job + '&from=' + off);
          off = r.len;
          if (r.out) { text += r.out; paint(out, text); out.scrollTop = out.scrollHeight; }
          if (r.done) {
            clearInterval(polling); polling = null;
            replace(status, el('span', { class: 'badge ' + (r.rc === 0 ? 'ok' : 'warn') }, r.rc === 0 ? T('готово') : T('код ') + r.rc));
            const m = text.match(/awg-report-\d{8}-\d{6}\.txt/);
            if (m) {
              const a = el('a', { class: 'btn sm primary', href: '/api/report/file?name=' + m[0], download: m[0] }, icon('download', 'sm'), T('Скачать отчёт'));
              replace(dl, a);
              if (payload.tool === 'report') a.click();     // отчёт сразу скачивается
            }
          }
        } catch (e) { clearInterval(polling); polling = null; replace(status, e.message); }
      };
      polling = setInterval(poll, 1000);
      S.timers.push(polling);
      poll();
    }
    const tiles = TOOLS.map(([k, name, ic, desc]) => el('div', { class: 'card tool' },
      el('div', { class: 'ti' }, el('span', { class: 'ib' }, icon(ic)), name), el('p', null, desc),
      el('div', null, el('button', { class: 'btn sm', onclick: async () => {
        if ((k === 'selftest-full' || k === 'switch-test') && !await confirmBox(name, k === 'switch-test' ? T('Основной канал будет «уронен» флагом на время теста. Трафик PBR ненадолго уйдёт на запасной канал.') : T('Туннели будут кратко отключены: трафик PBR остановится на несколько секунд.'), T('Запустить'))) return;
        runTool({ tool: k }, name);
      } }, icon('play', 'sm'), T('Запустить')))));
    const dom = el('input', { class: 'input', placeholder: 'youtube.com', autocapitalize: 'off', spellcheck: 'false' });
    const domGo = () => { if (dom.value.trim()) runTool({ tool: 'domain-check', domain: dom.value.trim() }, T('Проверка ') + dom.value.trim()); };
    dom.addEventListener('keydown', (e) => { if (e.key === 'Enter') domGo(); });
    const mtuSel = el('select', { class: 'input' });
    const spSel = el('select', { class: 'input' }), spSize = el('select', { class: 'input' }, [5, 10, 25, 50].map((x) => el('option', { value: x, selected: x === 10 }, x + T(' МБ'))));
    const pgSel = el('select', { class: 'input' }), pgHost = el('input', { class: 'input', value: '1.1.1.1', spellcheck: 'false', autocapitalize: 'off' });
    // ICMP часто режут провайдер или сервер туннеля: «авто» тогда меряет время TCP-подключения к :443
    const pgMode = el('select', { class: 'input', 'aria-label': T('Способ') }, el('option', { value: 'auto' }, T('авто')), el('option', { value: 'icmp' }, 'ICMP'), el('option', { value: 'tcp' }, 'TCP :443'));
    pgMode.style.width = 'auto';
    spSize.style.width = 'auto';
    const spHist = el('div');
    const loadSp = async () => {
      const r = await api('/api/speed');
      replace(spHist, r.history.length ? el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Когда')), el('th', null, T('Канал')), el('th', null, '↓'), el('th', null, '↑'), el('th', null, T('Задержка')))),
        el('tbody', null, r.history.slice(0, 8).map((x) => el('tr', null, el('td', { class: 'nowrap' }, fmtTime(x.t)), el('td', null, el('span', { class: 'mono' }, x.iface)),
          el('td', { class: 'nowrap' }, x.down_bps ? fmtBits(x.down_bps) : '—'), el('td', { class: 'nowrap' }, x.up_bps ? fmtBits(x.up_bps) : '—'), el('td', null, x.ping_ms ? x.ping_ms + T(' мс') : '—'))))) : el('div', { class: 'small muted' }, T('Замеров ещё не было')));
    };
    loadSp().catch(() => {});
    api('/api/overview').then((ov) => {
      updateChrome(ov);
      const opts = () => ov.tunnels.map((t) => el('option', { value: t.name }, t.label ? t.label + ' (' + t.name + ')' : t.name));
      replace(mtuSel, opts());
      replace(spSel, el('option', { value: 'all' }, T('все туннели и WAN')), opts(), el('option', { value: 'wan' }, T('WAN напрямую (') + (ov.wan.if || '?') + ')'));
      replace(pgSel, opts(), el('option', { value: 'wan' }, T('WAN напрямую')));
    }).catch(() => {});
    const watchDone = async () => { await new Promise((r) => setTimeout(r, 2000)); for (let i = 0; i < 300 && polling; i++) await new Promise((r) => setTimeout(r, 1000)); loadSp().catch(() => {}); };
    add(main, [
      head(T('Инструменты')),
      el('div', { class: 'grid g-2e' },
        card(T('Проверка домена'), el('div', null, el('p', { class: 'muted small' }, T('Куда пойдёт сайт, открывается ли он через туннель и напрямую, попал ли в наборы доменов.')),
          el('div', { class: 'input-group' }, dom, el('button', { class: 'btn primary', onclick: domGo }, icon('search', 'sm'), T('Проверить')))), { icon: 'globe' }),
        card(T('Подобрать и применить MTU'), el('div', null, el('p', { class: 'muted small' }, T('Найти MTU для туннеля и сразу записать его в конфиг (туннель перезапустится).')),
          el('div', { class: 'input-group' }, mtuSel, el('button', { class: 'btn', onclick: async () => {
            if (!await confirmBox(T('MTU для ') + mtuSel.value, T('Туннель будет перезапущен с новым MTU.'), T('Подобрать и применить'))) return;
            runTool({ tool: 'mtu-apply', name: mtuSel.value }, 'MTU ' + mtuSel.value);
          } }, icon('ruler', 'sm'), T('Применить')))), { icon: 'ruler' })),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-2e' },
        card(T('Скорость каналов'), el('div', null, el('p', { class: 'muted small' }, T('Загрузка и отдача через туннель и напрямую (speed.cloudflare.com). Сравните каналы между собой и с WAN.')),
          el('div', { class: 'input-group' }, spSel, spSize, el('button', { class: 'btn primary', onclick: () => { runTool({ tool: 'speedtest', iface: spSel.value, mb: +spSize.value }, T('Замер скорости')); watchDone(); } }, icon('activity', 'sm'), T('Замерить'))),
          el('div', { class: 'spacer' }), spHist), { icon: 'activity' }),
        card(T('Ping и трассировка'), el('div', null, el('p', { class: 'muted small' }, T('Проверить доступность адреса через выбранный туннель или напрямую.')),
          el('div', { class: 'input-group' }, pgHost, pgSel, pgMode),
          el('div', { class: 'spacer' }),
          el('div', { class: 'row' }, el('button', { class: 'btn', onclick: () => runTool({ ep: '/api/net', kind: 'ping', host: pgHost.value.trim(), iface: pgSel.value, mode: pgMode.value }, 'ping ' + pgHost.value) }, icon('activity', 'sm'), 'Ping'),
            el('button', { class: 'btn', onclick: () => runTool({ ep: '/api/net', kind: 'trace', host: pgHost.value.trim(), iface: pgSel.value }, T('трассировка ') + pgHost.value) }, icon('route', 'sm'), T('Трассировка')))), { icon: 'globe' })),
      el('div', { class: 'spacer' }),
      card(T('Сверка правил с эталоном (drift)'), el('div', null,
        el('p', { class: 'muted small' }, T('Эталон снимается после установки и обновления. Сверка покажет, какие правила iptables, ip rule, маршруты PBR и службы пропали или появились — и чьи они: набора или UniFi. «Вернуть правила набора» перезапускает только службы UDR-Amnezia; правила UniFi не трогаются никогда.')),
        el('div', { class: 'row wrap' },
          el('button', { class: 'btn primary', onclick: () => runTool({ tool: 'drift' }, T('Сверка')) }, icon('search', 'sm'), T('Сверить')),
          el('button', { class: 'btn', onclick: async () => { if (await confirmBox(T('Вернуть правила набора?'), T('Службы awg-failover, guard, self, subnets будут перезапущены (на секунды прерывается трафик PBR).'), T('Вернуть'))) runTool({ tool: 'drift-repair' }, T('Восстановление')); } }, icon('wrench', 'sm'), T('Вернуть правила набора')),
          el('button', { class: 'btn', onclick: async () => { if (await confirmBox(T('Принять текущее состояние?'), T('Текущие правила станут эталоном. Делайте это, когда всё работает (например, после изменения PBR в UniFi).'), T('Принять'))) runTool({ tool: 'drift-save' }, T('Новый эталон')); } }, icon('check', 'sm'), T('Принять текущее как эталон')))), { icon: 'layers' }),
      el('div', { class: 'spacer' }),
      el('div', { class: 'grid g-tools' }, tiles),
      el('div', { class: 'spacer' }), outCard]);
  };
  // вывод команд — в стиле страницы: строки OK/WARN/FAIL с значками, разделы заголовками, советы отдельно
  function paint(box, text) {
    clear(box);
    box.dataset.raw = text;
    let blank = false;
    for (let line of text.replace(/\x1b\[[0-9;]*m/g, '').split('\n')) {
      if (!line.trim()) { if (!blank && box.lastChild) box.appendChild(el('div', { class: 'osp' })); blank = true; continue; }
      blank = false;
      let m;
      const st = (lv, t) => box.appendChild(el('div', { class: 'ol ' + lv }, el('span', { class: 'oi' }, icon({ ok: 'check', warn: 'alert', crit: 'x', info: 'info' }[lv], 'sm')), el('span', { class: 'ot' }, TM(t))));
      if ((m = line.match(/^\s*(?:OK|ОК|✔|✓)\s+(.*)$/))) st('ok', m[1]);
      else if ((m = line.match(/^\s*(?:WARN|ВНИМАНИЕ|⚠|▲)\s+(.*)$/))) st('warn', m[1]);
      else if ((m = line.match(/^\s*(?:FAIL|ОШИБКА|✖|✗)\s+(.*)$/))) st('crit', m[1]);
      else if ((m = line.match(/^\s*(?:INFO|·)\s+(.*)$/))) st('info', m[1]);
      else if ((m = line.match(/^\s*={2,}\s*(.*?)\s*=*\s*$/)) || (m = line.match(/^(\d+\.\s+\S.*)$/)) || (m = line.match(/^--\s+(.*)$/))) box.appendChild(el('div', { class: 'oh' }, TM(m[1])));
      else if ((m = line.match(/^\s*(?:что делать|Что сделать|↳)\s*:?\s*(.*)$/i))) box.appendChild(el('div', { class: 'oadv' }, icon('chev', 'sm'), el('span', null, m[1])));
      else if (/^\s*(Итог|ИТОГ)/.test(line)) box.appendChild(el('div', { class: 'osum' }, TM(line.trim())));
      else box.appendChild(el('div', { class: 'op' }, line.replace(/^\s{0,6}/, '')));
    }
  }
  function dlText(name, text, type) {
    const a = el('a', { href: URL.createObjectURL(new Blob([text], { type: type || 'text/plain;charset=utf-8' })), download: name });
    document.body.appendChild(a); a.click(); a.remove();
  }
  function outTools(box, name) {
    return [el('button', { class: 'btn sm ghost icon', title: T('Копировать'), 'aria-label': T('Копировать'), onclick: async () => {
      try { await navigator.clipboard.writeText(box.dataset.raw || ''); ok(T('Скопировано')); } catch (e) { err(T('Браузер не дал скопировать: выделите текст вручную')); }
    } }, icon('copy', 'sm')),
    el('button', { class: 'btn sm ghost icon', title: T('Скачать'), 'aria-label': T('Скачать'), onclick: () => dlText((typeof name === 'function' ? name() : name) + '-' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '') + '.txt', box.dataset.raw || '') }, icon('download', 'sm'))];
  }

