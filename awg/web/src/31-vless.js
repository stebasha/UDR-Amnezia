  // ===================================================================== VLESS / Reality через Xray (#42)
  // подписка по ссылке (как в Happ / v2rayN), серверы по странам с задержкой, туннель — участник цепочки переключения
  function flagOf(cc) { return /^[A-Z]{2}$/.test(cc || '') ? String.fromCodePoint(...[...cc].map((c) => 0x1F1A5 + c.charCodeAt(0))) : ''; }
  function pingBadge(p) {
    if (p == null) return el('span', { class: 'small muted' }, '—');
    if (p < 0) return el('span', { class: 'badge warn' }, T('нет ответа'));
    return el('span', { class: 'badge ' + (p < 120 ? 'ok' : p < 300 ? '' : 'warn') }, p + T(' мс'));
  }
  async function vlessDialog(reload, focus) {
    let r;
    try { r = await api('/api/vless'); } catch (e) { err(e); return; }
    const body = el('div');
    let follow = null;
    const m = modal(T('VLESS / Reality'), body, [el('button', { class: 'btn', onclick: () => m.close() }, T('Закрыть'))], { wide: true, sticky: true, onclose: () => clearTimeout(follow) });
    const again = async () => { try { r = await api('/api/vless'); paint(); } catch (e) { err(e); } };
    function paint() {
      clear(body);
      // ---- Xray
      const x = r.xray;
      const inst = el('button', { class: 'btn' + (x.installed ? '' : ' primary'), disabled: x.job }, icon('download', 'sm'), x.installed ? T('Обновить Xray') : T('Установить Xray'));
      inst.addEventListener('click', async () => {
        const pw = await promptPw(x.installed ? T('Обновить Xray?') : T('Установить Xray?'),
          T('Последний официальный релиз XTLS/Xray-core с github.com, сверка SHA-256. Около 30 МБ на диске и 30–60 МБ памяти, пока работает туннель VLESS. Туннели VLESS перезапустятся.'));
        if (pw == null) return;
        try { ok((await api('/api/vless/xray', { current: pw })).msg); await again(); } catch (e) { err(e); }
      });
      const log = x.log ? el('details', { class: 'fgroup', open: x.job }, el('summary', null, T('Журнал установки')), el('pre', { class: 'logbox' }, x.log)) : null;
      add(body, [
        el('div', { class: 'row between wrap' },
          el('div', null, el('b', null, 'Xray '), x.installed ? el('span', { class: 'badge ok' }, x.version || '?') : el('span', { class: 'badge warn' }, T('не установлен')),
            x.job ? el('span', { class: 'badge' }, el('span', { class: 'spinner sm' }), T(' идёт установка')) : null),
          inst),
        el('p', { class: 'small muted' }, T('Туннель VLESS работает через Xray: интерфейс TUN, маршрут, kill switch и переключение — как у AmneziaWG. Xray ставится только из официальных релизов XTLS.')),
        log]);
      if (x.job) { clearTimeout(follow); follow = setTimeout(again, 3000); }
      // ---- подписки
      const url = el('input', { class: 'input mono', placeholder: 'https://…/sub/…', spellcheck: 'false', autocomplete: 'off' });
      const lab = el('input', { class: 'input', placeholder: T('например, Мой VPN'), maxlength: 40 });
      const addS = el('button', { class: 'btn primary' }, icon('plus', 'sm'), T('Добавить подписку'));
      addS.addEventListener('click', () => busy(addS, async () => {
        try { ok((await api('/api/vless/sub', { url: url.value.trim(), label: lab.value.trim() })).msg); url.value = ''; await again(); } catch (e) { err(e); }
      }));
      const subRows = r.subs.map((s) => {
        const upd = el('button', { class: 'btn sm icon', title: T('Обновить список серверов'), 'aria-label': T('Обновить') }, icon('refresh', 'sm'));
        upd.addEventListener('click', () => busy(upd, async () => { try { ok((await api('/api/vless/sub/refresh', { id: s.id })).msg); await again(); reload(); } catch (e) { err(e); } }));
        const png = el('button', { class: 'btn sm icon', title: T('Замерить задержку'), 'aria-label': T('Задержка') }, icon('activity', 'sm'));
        png.addEventListener('click', () => busy(png, async () => { try { ok((await api('/api/vless/ping', { id: s.id })).msg); await again(); } catch (e) { err(e); } }));
        const del = el('button', { class: 'btn sm icon', title: T('Убрать подписку'), 'aria-label': T('Убрать') }, icon('trash', 'sm'));
        del.addEventListener('click', async () => {
          if (!await confirmBox(T('Убрать подписку ') + s.label + '?', T('Роутер забудет адрес подписки и список серверов.'), T('Убрать'), true)) return;
          try { await api('/api/vless/sub/remove', { id: s.id }); await again(); } catch (e) { err(e); }
        });
        return el('tr', null,
          el('td', null, el('b', null, s.label), el('div', { class: 'small muted mono' }, s.url)),
          el('td', null, s.count + T(' серв.'), s.skipped ? el('div', { class: 'small muted' }, T('пропущено: ') + s.skipped) : null),
          el('td', null, el('span', { class: 'small' }, s.countries.map((c) => flagOf(c) + ' ' + c).join('  ') || '—')),
          el('td', null, s.updated ? fmtAge(Math.max(0, Math.floor(Date.now() / 1000) - s.updated)) : '—', s.err ? el('div', { class: 'small' }, el('span', { class: 'badge warn' }, s.err)) : null),
          el('td', { class: 'nowrap' }, upd, png, del));
      });
      add(body, [el('h3', null, T('Подписки')),
        r.subs.length ? el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('tbody', null, subRows))) : el('p', { class: 'muted small' }, T('Подписок нет. Ссылку подписки даёт провайдер VPN (та же, что для Happ, v2rayN, Hiddify).')),
        el('div', { class: 'form-grid' }, el('div', { class: 'field' }, el('label', null, T('Адрес подписки')), url, el('span', { class: 'hint' }, T('Только https. Обновляется раз в сутки; сервер, пропавший из подписки, туннель сменит сам.'))),
          el('div', { class: 'field' }, el('label', null, T('Название')), lab)),
        addS]);
      // ---- туннели
      add(body, [el('div', { class: 'spacer' }), el('h3', null, T('Туннели VLESS'))]);
      for (const t of r.tunnels) add(body, tunnelForm(t));
      if (!r.tunnels.some((t) => t.name === focus) || !focus) add(body, el('details', { class: 'fgroup', open: !r.tunnels.length && r.subs.length > 0 }, el('summary', null, T('Новый туннель VLESS')), el('div', { class: 'spacer' }), tunnelForm(null)));
    }
    function tunnelForm(t) {
      const subs = r.subs;
      const nm = el('input', { class: 'input mono', value: t ? t.name : (r.names.includes('awgvless') ? 'awgvless2' : 'awgvless'), disabled: !!t, spellcheck: 'false' });
      const lab = el('input', { class: 'input', placeholder: T('например, VLESS Финляндия'), maxlength: 40 });
      const sub = el('select', { class: 'input' }, subs.map((s) => el('option', { value: s.id, selected: t && t.sub === s.id }, s.label + ' (' + s.count + ')')));
      const cty = el('select', { class: 'input' });
      const srv = el('select', { class: 'input' });
      const fill = () => {
        const s = subs.find((x) => x.id === sub.value) || { servers: [], countries: [] };
        const cc = cty.value || (t ? t.country : '');
        replace(cty, el('option', { value: '' }, T('любая — самый быстрый сервер')),
          s.countries.map((c) => el('option', { value: c, selected: c === cc }, flagOf(c) + ' ' + c + ' (' + s.servers.filter((x) => x.country === c).length + ')')));
        const list = s.servers.filter((x) => !cty.value || x.country === cty.value).slice().sort((a, b) => (a.ping < 0 ? 1e9 : a.ping) - (b.ping < 0 ? 1e9 : b.ping));
        replace(srv, el('option', { value: '' }, T('автоматически — самый быстрый в стране')),
          list.map((x) => el('option', { value: x.id, selected: t && t.mode === 'fixed' && t.server && t.server.id === x.id },
            (flagOf(x.country) + ' ' + (x.remark || x.host)).trim() + ' · ' + x.security + '/' + x.type + ' · ' + (x.ping >= 0 ? x.ping + T(' мс') : T('нет ответа')))));
      };
      sub.addEventListener('change', () => { cty.value = ''; fill(); });
      cty.addEventListener('change', fill);
      fill();
      const go = el('button', { class: 'btn primary', disabled: !subs.length || !r.xray.installed }, icon(t ? 'switch' : 'plus', 'sm'), t ? T('Применить') : T('Создать туннель'));
      go.addEventListener('click', async () => {
        const pw = await promptPw(t ? T('Сменить сервер ') + t.name + '?' : T('Создать туннель VLESS?'),
          t ? T('Туннель перезапустится с новым сервером: если он активный, трафик PBR прервётся на несколько секунд.') : T('Туннель добавится в цепочку переключения как дополнительный. Чтобы пустить в него трафик — «Маршруты» или «Активировать».'));
        if (pw == null) return;
        try {
          const x = await api('/api/vless/tunnel', { name: nm.value.trim(), sub: sub.value, country: cty.value, server: srv.value, label: lab.value.trim(), current: pw });
          (x.ok ? ok : err)(x.msg); await again(); reload();
        } catch (e) { err(e); }
      });
      const rm = t ? el('button', { class: 'btn danger' }, icon('trash', 'sm'), T('Удалить ') + t.name) : null;
      if (rm) rm.addEventListener('click', async () => {
        const pw = await promptPw(T('Удалить ') + t.name + '?', T('Туннель будет остановлен и убран из сторожа, конфиг Xray удалён. Подписка останется.'));
        if (pw == null) return;
        try { ok((await api('/api/vless/tunnel/remove', { name: t.name, current: pw })).msg); await again(); reload(); } catch (e) { err(e); }
      });
      const s = t && t.server;
      return el('div', { class: 'fgroup' },
        t ? el('div', { class: 'row between wrap' },
          el('div', null, el('span', { class: 'dot ' + (t.up && t.check >= 0 && t.check < 180 ? 'ok' : t.up ? 'warn' : 'crit') }), el('b', { class: 'mono' }, ' ' + t.name),
            el('span', { class: 'small muted' }, s ? ' · ' + (flagOf(s.country) + ' ' + (s.remark || '')).trim() + ' · ' + s.security + '/' + s.type : T(' · сервер пропал из подписки'))),
          s ? pingBadge(s.ping) : null) : null,
        el('div', { class: 'form-grid' },
          el('div', { class: 'field' }, el('label', null, T('Имя туннеля')), nm),
          t ? null : el('div', { class: 'field' }, el('label', null, T('Название')), lab),
          el('div', { class: 'field' }, el('label', null, T('Подписка')), sub),
          el('div', { class: 'field' }, el('label', null, T('Страна')), cty),
          el('div', { class: 'field' }, el('label', null, T('Сервер')), srv, el('span', { class: 'hint' }, T('Автоматически: при обновлении подписки туннель сам перейдёт на лучший сервер страны, если его сервер пропадёт.')))),
        el('div', { class: 'row wrap' }, go, rm, !r.xray.installed ? el('span', { class: 'small muted' }, T('Сначала установите Xray.')) : null));
    }
    paint();
  }
