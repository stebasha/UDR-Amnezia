  // автоподбор обфускации (#33): перебор наборов, проверка, оценка; «Применить» — только по кнопке
  function tuneCard() {
    const box = el('div', { class: 'stack' }, el('div', { class: 'muted small' }, T('Загрузка…')));
    let polling = false;
    const load = async () => {
      let r;
      try { r = await api('/api/tune'); } catch (e) { replace(box, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, String(e.message || e)))); return; }
      const lab = (t) => { const x = S.ov && S.ov.tunnels.find((y) => y.name === t.name); return (x && x.label ? x.label + ' (' + t.name + ')' : t.name) + (t.active ? T(' — активный') : ''); };
      const first = (r.tunnels.find((t) => !t.active) || {}).name;
      const sel = el('select', { class: 'input' }, r.tunnels.map((t) => el('option', { value: t.name, selected: t.name === first }, lab(t))));
      const mode = el('select', { class: 'input' });
      const cnt = el('input', { class: 'input mono', value: '5', inputmode: 'numeric' });
      const act = el('input', { type: 'checkbox' });
      const fillMode = () => {
        const t = r.tunnels.find((x) => x.name === sel.value) || {};
        replace(mode, el('option', { value: 'client' }, T('Только роутер (Jc, Jmin, Jmax) — любой туннель')),
          t.server ? el('option', { value: 'server', selected: true }, T('Роутер и свой VPS (Jc…H4) — согласованно')) : null,
          t.xui ? el('option', { value: 'xui', selected: !t.server }, T('Роутер и сервер 3x-ui (Jc…H4) — если клиент в подключении один')) : null);
      };
      sel.addEventListener('change', fillMode); fillMode();
      const log = el('div', { class: 'out' + (r.log ? '' : ' hidden') });
      if (r.log) paint(log, r.log);
      const go = el('button', { class: 'btn primary', disabled: r.running }, icon('activity', 'sm'), r.running ? T('Подбор идёт…') : T('Подобрать'));
      go.addEventListener('click', async () => {
        const pw = await promptPw(T('Подобрать параметры для ') + sel.value + '?', T('Туннель по очереди пробует наборы: на каждый — до полутора минут без связи по этому туннелю, замер скорости — 5 МБ трафика. В конце возвращается исходный набор. Лучший ставится только по кнопке «Применить».'));
        if (pw == null) return;
        try { ok(TM((await api('/api/tune/run', { tunnel: sel.value, mode: mode.value, count: cnt.value.trim(), active: act.checked, current: pw })).msg)); follow(); } catch (e) { err(e); }
      });
      const rows = r.rows.map((x) => el('tr', { class: x.n === r.best ? 'hl' : '' },
        el('td', { class: 'mono' }, x.n === 0 ? T('сейчас') : '№' + x.n),
        el('td', null, x.ok ? el('span', { class: 'badge ok' }, T('работает')) : el('span', { class: 'badge crit' }, T('нет связи'))),
        el('td', { class: 'mono small' }, x.ok ? x.loss + '% · ' + x.rtt + T(' мс · ') + x.mbps + T(' Мбит/с') : '—'),
        el('td', null, el('b', null, String(x.score)), x.n === r.best ? el('span', { class: 'badge ok' }, T('лучший')) : null),
        el('td', { class: 'mono small' }, x.params),
        el('td', { class: 'r' }, x.ok && x.n !== 0 ? el('button', { class: 'btn sm' + (x.n === r.best ? ' primary' : ''), disabled: r.running, onclick: async () => {
          const pw = await promptPw(T('Поставить набор №') + x.n + T(' на ') + r.head.tunnel + '?', r.head.mode === 'server' ? T('Параметры поменяются на VPS и роутере одновременно; не заработает — обе стороны вернутся.') : r.head.mode === 'xui' ? T('Параметры поменяются в 3x-ui и на роутере одновременно; не заработает — обе стороны вернутся.') : T('Меняется только конфиг роутера (прежний — в «Истории» туннеля).'));
          if (pw == null) return;
          try { const y = await api('/api/tune/apply', { n: x.n, current: pw }); (y.ok ? ok : err)(TM(y.msg)); if (y.job) follow(); else load(); } catch (e) { err(e); }
        } }, T('Применить')) : null)));
      replace(box,
        el('p', { class: 'muted small' }, T('Если провайдер начал узнавать или замедлять AmneziaWG: роутер перебирает наборы параметров обфускации, проверяет каждый (handshake, интернет, потери, задержка, скорость) и ставит оценку. «Только роутер» меняет параметры мусорных пакетов, которые сервер не сверяет, — подходит и для туннеля провайдера, и для 3x-ui. «Роутер и свой VPS» меняет и S1, S2, H1–H4 на вашем сервере.')),
        el('div', { class: 'form-grid' },
          el('div', { class: 'field' }, el('label', null, T('Туннель')), sel),
          el('div', { class: 'field' }, el('label', null, T('Что менять')), mode),
          el('div', { class: 'field' }, el('label', null, T('Новых наборов')), cnt, el('span', { class: 'hint' }, T('1–12; первым меряется текущий')))),
        el('label', { class: 'row' }, act, T('Разрешить на активном канале (трафик устройств на время подбора пойдёт с перерывами)')),
        el('div', { class: 'row' }, go),
        autoRow(r),
        r.rows.length ? el('div', null, el('div', { class: 'small muted' }, T('Последний подбор: ') + r.head.tunnel + ' · ' + (r.head.mode === 'server' ? T('роутер и VPS') : r.head.mode === 'xui' ? T('роутер и 3x-ui') : T('только роутер')) + ' · ' + fmtTime(r.head.ts, true)),
          el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Набор')), el('th', null, T('Связь')),
            el('th', null, T('Потери · задержка · скорость')), el('th', null, T('Оценка')), el('th', null, T('Параметры')), el('th', null, ''))), el('tbody', null, rows)))) : null,
        log);
      if (r.running && !polling) follow();
    };
    function autoRow(r) {   // #36: подбор сам при деградации неактивного канала, итог — в Telegram с кнопкой «Применить»
      const cb = el('input', { type: 'checkbox', checked: r.auto });
      cb.addEventListener('change', async () => {
        try { await api('/api/settings', { values: { AUTO_TUNE: cb.checked ? 'yes' : 'no' } }); ok(T('Сохранено')); } catch (e) { cb.checked = !cb.checked; err(e); }
      });
      return el('div', { class: 'setting' },
        el('div', { class: 'txt' }, el('b', null, T('Подбирать самому при деградации')),
          el('span', null, T('Неактивный канал 15 минут без handshake или с потерями выше порога — роутер сам подбирает «только роутер» (не чаще раза в сутки на канал) и присылает в Telegram лучший набор с кнопкой «Применить». Активный канал не трогается.')),
          r.auto && !r.bot ? el('span', { class: 'badge warn' }, T('нужен Telegram-бот (служба awg-bot)')) : null),
        el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, cb, el('span', { class: 'knob' }))));
    }
    async function follow() {
      if (polling) return;
      polling = true;
      for (let i = 0; i < 600; i++) {
        await new Promise((ok2) => setTimeout(ok2, 3000));
        let x;
        try { x = await api('/api/tune'); } catch (e) { continue; }
        if (!x.running) break;
        const lg = box.querySelector('.out');
        if (lg) { lg.classList.remove('hidden'); paint(lg, x.log); lg.scrollTop = lg.scrollHeight; }
      }
      polling = false;
      load();
    }
    load();
    return card(T('Подбор параметров обфускации'), box, { icon: 'shield' });
  }
