  // ===================================================================== НАСТРОЙКИ
  const SET_TABS = [['failover', T('Переключение')], ['services', T('Службы')], ['telegram', 'Telegram'], ['ha', 'Home Assistant'], ['users', T('Пользователи и 2FA')], ['web', T('Панель и сертификат')], ['backups', T('Резервные копии')], ['vps', T('Свой VPS')], ['system', T('Система и обновление')]];
  PAGES.settings = function (main, sub) {
    const cur = SET_TABS.some((t) => t[0] === sub) ? sub : 'failover';
    add(main, [head(T('Настройки')), tabs(SET_TABS, cur, (id) => { location.hash = '#/settings/' + id; })]);
    const body = el('div', { class: 'stack' });
    main.appendChild(body);
    ({ failover: setFailover, services: setServices, telegram: setTelegram, ha: setHa, users: setUsers, web: setWeb, backups: setBackups, vps: setVps, system: setSystem })[cur](body);
  };
  async function setFailover(body) {
    try {
      const d = await settings(true);
      add(body, [
        settingsForm(T('Переключение каналов'), 'switch', ['RECOVER_SEC', 'QUALITY', 'QUALITY_LOSS', 'QUALITY_RTT', 'MIN_DWELL'], d,
          el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Сторож проверяет каналы каждые несколько секунд (HTTPS к 1.1.1.1, 8.8.8.8, 9.9.9.9). При падении активного — уходит на следующий по приоритету; на основной возвращается после стабильной работы.')))),
        settingsForm(T('Мониторинг'), 'activity', ['METRICS_PORT'], d)]);
    } catch (e) { err(e); }
  }
  async function setServices(body) {
    const tb = el('tbody');
    const load = async () => {
      const r = await api('/api/services');
      replace(tb, Object.entries(r.services).map(([u, s]) => {
        const act = (a, label, cls) => el('button', { class: 'btn sm ' + (cls || ''), onclick: async (e) => {
          if (a === 'disable' && !await confirmBox(T('Выключить ') + u + '?', T('Служба будет остановлена и убрана из автозапуска, её правила — удалены.'), T('Выключить'), true)) return;
          await busy(e.currentTarget, async () => { try { const x = await api('/api/service', { name: u, action: a }); (x.ok ? ok : err)(x.msg); load(); } catch (ex) { err(ex); } });
        } }, label);
        return el('tr', null,
          el('td', null, el('span', { class: 'row' }, el('span', { class: 'dot ' + (s.active ? 'ok' : s.installed ? 'crit' : '') }), el('b', null, u))),
          el('td', { class: 'muted' }, TM(s.info)),
          el('td', null, s.active ? el('span', { class: 'badge ok' }, T('работает')) : s.installed ? el('span', { class: 'badge crit' }, T('стоит')) : el('span', { class: 'badge' }, T('выключена'))),
          el('td', { class: 'r nowrap' }, s.installed ? [act('restart', T('Перезапуск')), ' ', u !== 'awg-failover' ? act('disable', T('Выключить'), 'danger') : null] : (s.available ? act('enable', T('Включить'), 'primary') : el('span', { class: 'muted small' }, T('нет файла службы')))));
      }));
    };
    body.appendChild(card(T('Службы набора'), el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Служба')), el('th', null, T('Назначение')), el('th', null, T('Состояние')), el('th', { class: 'r' }, ''))), tb)),
      { icon: 'cpu', flush: true, right: el('a', { class: 'btn sm', href: '#/logs/journal' }, T('Журнал')) }));
    every(10000, load);
  }
  async function setTelegram(body) {
    let r;
    try { r = await api('/api/telegram'); } catch (e) { err(e); return; }
    const tok = el('input', { class: 'input mono', placeholder: r.configured ? r.token + T(' (оставьте пустым, чтобы не менять)') : '123456789:AA…', autocomplete: 'off', spellcheck: 'false' });
    const chat = el('input', { class: 'input mono', value: r.chat, placeholder: '123456789 987654321' });
    const viewers = el('input', { class: 'input mono', value: r.viewers || '', placeholder: T('пусто — никого') });
    const rt = el('input', { class: 'input mono', value: r.report_time.replace(/^(\d\d)(\d\d)$/, '$1:$2'), placeholder: '09:00' });
    const nw = el('input', { type: 'checkbox', checked: r.no_wan });
    const en = el('input', { type: 'checkbox', checked: r.notify || !r.configured });
    const bot = el('input', { type: 'checkbox', checked: r.bot });
    const res = el('div', { class: 'res hidden' });
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/telegram', { token: tok.value.trim(), chat: chat.value.trim(), viewers: viewers.value.trim(), report_time: rt.value.trim(), no_wan: nw.checked, enable_notify: en.checked, enable_bot: bot.checked });
        res.textContent = x.msg; res.classList.remove('hidden'); ok(T('Сохранено')); tok.value = '';
      } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('tg', 'sm'), T('Тестовое сообщение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/telegram/test', {}); (x.ok ? ok : err)(x.msg); } catch (e) { err(e); } }));
    const sw = (inp, t, h) => el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, t), el('span', null, h)), el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }))));
    body.appendChild(card('Telegram', el('div', null,
      el('div', { class: 'row wrap' }, el('span', { class: 'badge ' + (r.configured ? 'ok' : '') }, r.configured ? T('настроен') : T('не настроен')),
        el('span', { class: 'badge ' + (r.notify ? 'ok' : '') }, T('уведомления: ') + (r.notify ? T('работают') : T('выкл'))),
        el('span', { class: 'badge ' + (r.bot ? 'ok' : '') }, T('бот: ') + (r.bot ? T('работает') : T('выкл')))),
      el('div', { class: 'spacer' }),
      el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Токен бота')), tok, el('span', { class: 'hint' }, T('От @BotFather. В панели не показывается целиком.'))),
        el('div', { class: 'field' }, el('label', null, T('Администраторы (chat id)')), chat, el('span', { class: 'hint' }, T('Через пробел. Полный доступ: переключение, службы, отчёты. Свой id: напишите боту /id или @userinfobot.'))),
        el('div', { class: 'field' }, el('label', null, T('Только просмотр (chat id)')), viewers, el('span', { class: 'hint' }, T('Через пробел: видят состояние, события, роутер и получают уведомления, но ничего не меняют.'))),
        el('div', { class: 'field' }, el('label', null, T('Ежедневный отчёт')), rt, el('span', { class: 'hint' }, T('Время ЧЧ:ММ')))),
      sw(en, T('Уведомления'), T('Переключения каналов, падения, возвраты, ежедневный отчёт.')),
      sw(bot, T('Бот с кнопками'), T('Меню кнопками: состояние, каналы и переключение, события, проверки, роутер, клиенты, тишина уведомлений. Чужим чатам бот сообщает только их chat id.')),
      r.muted && r.muted.length ? el('div', { class: 'small muted' }, T('Уведомления временно выключены в чатах: ') + r.muted.join(', ')) : null,
      sw(nw, T('Не слать напрямую через WAN'), T('Если туннели лежат, уведомления не пойдут мимо VPN (тише, но можно не узнать о сбое).')),
      res), { icon: 'tg', foot: [test, save] }));
    const hc = await hooksCard();
    if (hc) body.appendChild(hc);
  }
  // вебхук и ntfy (#14): те же события, что в Telegram. Адрес вебхука, заголовок и токен ntfy в браузер не возвращаются.
  async function hooksCard() {
    let r;
    try { r = await api('/api/hooks'); } catch (e) { err(e); return null; }
    const keep = T('задан — оставьте пустым, чтобы не менять');
    const hook = el('input', { class: 'input mono', placeholder: r.hook_set ? r.hook + ' (' + keep + ')' : 'https://example.com/hook', spellcheck: 'false', autocomplete: 'off' });
    const hdr = el('input', { class: 'input mono', placeholder: r.header_set ? keep : 'Authorization: Bearer …', spellcheck: 'false', autocomplete: 'off' });
    const ntfy = el('input', { class: 'input mono', value: r.ntfy, placeholder: 'https://ntfy.sh/my-udr-topic', spellcheck: 'false' });
    const ntok = el('input', { class: 'input mono', type: 'password', placeholder: r.ntfy_token_set ? keep : T('если тема закрыта'), autocomplete: 'off' });
    const clr = (label, key) => r[key] ? el('label', { class: 'small muted' }, el('input', { type: 'checkbox', 'data-k': key }), ' ' + label) : null;
    const c1 = clr(T('убрать вебхук'), 'hook_set'), c2 = clr(T('убрать заголовок'), 'header_set'), c3 = clr(T('убрать токен'), 'ntfy_token_set');
    const on = (c) => !!(c && c.querySelector('input').checked);
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/hooks', { hook: hook.value.trim(), header: hdr.value.trim(), ntfy: ntfy.value.trim(), ntfy_token: ntok.value.trim(),
          hook_clear: on(c1), header_clear: on(c2), ntfy_token_clear: on(c3) });
        ok(x.msg.split('\n')[0]); hook.value = hdr.value = ntok.value = '';
      } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Тестовое сообщение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/hooks/test', {}); (x.ok ? ok : err)(x.msg); } catch (e) { err(e); } }));
    return card(T('Вебхук и ntfy'), el('div', null,
      el('p', { class: 'muted small' }, T('Те же события, что в Telegram: переключения, падения, возвраты, отчёт, перезагрузка, прошивка, сбой автокопии. Отправляются обычным маршрутом роутера — подойдут адреса в LAN (Home Assistant, свой ntfy).')),
      el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Вебхук (POST, JSON)')), hook, c1, el('span', { class: 'hint' }, T('Тело: {"source","host","level","time","text"}; level — critical, warning, ok или info.'))),
        el('div', { class: 'field' }, el('label', null, T('Заголовок вебхука')), hdr, c2, el('span', { class: 'hint' }, T('Необязательно, например для авторизации.'))),
        el('div', { class: 'field' }, el('label', null, T('ntfy: адрес темы')), ntfy, el('span', { class: 'hint' }, T('ntfy.sh или свой сервер; приоритет по важности события.'))),
        el('div', { class: 'field' }, el('label', null, T('ntfy: токен')), ntok, c3))), { icon: 'bell', foot: [test, save] });
  }
