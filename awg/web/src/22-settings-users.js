  async function setUsers(body) {
    let r;
    try { r = await api('/api/users'); } catch (e) { err(e); return; }
    const me = r.users.find((u) => u.me) || { name: S.user, totp: false };
    const list = el('tbody', null, r.users.map((u) => el('tr', null,
      el('td', null, el('b', null, u.name), u.me ? el('span', { class: 'badge accent' }, T('вы')) : null),
      el('td', null, u.totp ? el('span', { class: 'badge ok' }, '2FA') : el('span', { class: 'badge' }, T('без 2FA'))),
      el('td', { class: 'r' }, u.me ? null : el('button', { class: 'btn sm danger', onclick: async () => {
        const pw = await promptPw(T('Удалить ') + u.name + '?', T('Пользователь будет удалён, его сеансы закрыты.'));
        if (pw == null) return;
        try { await api('/api/user/delete', { user: u.name, current: pw }); ok(T('Удалён')); location.reload(); } catch (e) { err(e); }
      } }, T('Удалить'))))));
    const un = el('input', { class: 'input', value: S.user, autocapitalize: 'off', spellcheck: 'false', autocomplete: 'username' });
    const p1 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const p2 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const cur = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      if (p1.value !== p2.value) { err(T('пароли не совпадают')); return; }
      try { const x = await api('/api/passwd', { user: un.value.trim(), password: p1.value, current: cur.value }); ok(x.msg); p1.value = p2.value = cur.value = ''; setTimeout(() => location.reload(), 800); } catch (e) { err(e); }
    }));
    const tf = el('div');
    const totpView = () => {
      if (me.totp) {
        const off = el('button', { class: 'btn danger' }, T('Выключить 2FA'));
        off.addEventListener('click', async () => {
          const pw = await promptPw(T('Выключить 2FA?'), T('Вход будет только по паролю.'));
          if (pw == null) return;
          try { await api('/api/totp/disable', { current: pw }); me.totp = false; ok(T('2FA выключена')); totpView(); } catch (e) { err(e); }
        });
        replace(tf, el('div', { class: 'alert ok' }, icon('okc'), el('div', null, T('Второй фактор включён: при входе нужен код из приложения.'))), el('div', { class: 'spacer' }), off);
      } else {
        const on = el('button', { class: 'btn primary' }, icon('key', 'sm'), T('Включить 2FA'));
        on.addEventListener('click', async () => {
          let b;
          try { b = await api('/api/totp/begin', {}); } catch (e) { err(e); return; }
          const code = el('input', { class: 'input mono', inputmode: 'numeric', maxlength: 6, placeholder: '000000', autocomplete: 'one-time-code' });
          let qr = null;
          try { qr = qrSvg(b.uri); } catch (e) { qr = null; }
          const go = async () => {
            try { await api('/api/totp/enable', { secret: b.secret, code: code.value }); me.totp = true; m.close(); ok(T('2FA включена')); totpView(); } catch (e) { err(e); }
          };
          code.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
          const m = modal(T('Включить 2FA'), el('div', null,
            el('p', null, T('Отсканируйте код в Google Authenticator, Aegis, 1Password или другом приложении TOTP, затем введите 6 цифр.')),
            qr, el('div', { class: 'secret-box' }, b.secret.replace(/(.{4})/g, '$1 ').trim()),
            el('div', { class: 'small muted' }, T('Если камеры нет — введите ключ вручную (тип: по времени, 6 цифр, 30 с).')),
            el('div', { class: 'spacer' }), el('div', { class: 'field' }, el('label', null, T('Код из приложения')), code),
            el('div', { class: 'small muted' }, T('Потеряли телефон — на роутере: '), el('code', null, 'python3 /data/awg/web/panel.py totp-off ' + S.user))),
          [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), el('button', { class: 'btn primary', onclick: go }, T('Включить'))], { sticky: true });
          setTimeout(() => code.focus(), 50);
        });
        replace(tf, el('p', { class: 'muted' }, T('Код из приложения на телефоне в дополнение к паролю. Рекомендуется, если панель открывают несколько человек или в LAN есть гостевые устройства.')), on);
      }
    };
    totpView();
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Пользователи'), el('table', { class: 'tbl' }, list), { icon: 'users', flush: true }),
        card(T('Двухфакторная защита (') + S.user + ')', tf, { icon: 'key' })),
      card(T('Пароль: сменить свой или добавить пользователя'), el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Имя пользователя')), un, el('span', { class: 'hint' }, T('Новое имя — новый пользователь'))),
        el('div', { class: 'field' }, el('label', null, T('Новый пароль')), p1, el('span', { class: 'hint' }, T('Не короче 10 символов'))),
        el('div', { class: 'field' }, el('label', null, T('Повторите')), p2),
        el('div', { class: 'field' }, el('label', null, T('Ваш текущий пароль')), cur)), { icon: 'lock', foot: save }),
      await sessionsCard(), await tokensCard()]);
  }
  // токены API (#6): для Home Assistant, скриптов, мониторинга. Сам токен показывается один раз.
  const tokHint = (p) => { p.style.padding = '0 16px'; return p; };   // через CSSOM: атрибут style запрещён CSP
  async function tokensCard() {
    const tb = el('tbody');
    const ROLE_T = { read: T('только чтение'), admin: T('управление') };
    const load = async () => {
      const r = await api('/api/tokens');
      replace(tb, r.tokens.length ? r.tokens.map((x) => el('tr', null,
        el('td', null, el('b', null, x.name), ' ', el('span', { class: 'badge ' + (x.role === 'admin' ? 'warn' : 'outline') }, ROLE_T[x.role] || x.role),
          x.expired ? el('span', { class: 'badge crit' }, T('истёк')) : null,
          el('div', { class: 'small muted' }, T('создал ') + x.user + ' · ' + fmtTime(x.created) + (x.expires ? T(' · до ') + fmtTime(x.expires) : T(' · бессрочно')))),
        el('td', { class: 'nowrap' }, x.last_used ? [fmtAge(Math.floor(Date.now() / 1000) - x.last_used), el('div', { class: 'small muted mono' }, x.last_ip)] : el('span', { class: 'muted' }, T('не использовался'))),
        el('td', { class: 'r' }, el('button', { class: 'btn sm danger', onclick: async () => {
          if (!await confirmBox(T('Отозвать токен?'), T('Всё, что пользуется токеном «') + x.name + T('», перестанет получать доступ.'), T('Отозвать'), true)) return;
          try { await api('/api/token/revoke', { id: x.id }); ok(T('Токен отозван')); load(); } catch (e) { err(e); }
        } }, T('Отозвать'))))) : el('tr', null, el('td', { class: 'muted' }, T('Токенов нет'))));
    };
    load().catch(err);
    const add = el('button', { class: 'btn sm primary', onclick: () => {
      const nm = el('input', { class: 'input', maxlength: 40, placeholder: 'home-assistant' });
      const role = el('select', { class: 'input' }, el('option', { value: 'read' }, T('только чтение')), el('option', { value: 'admin' }, T('управление (переключение каналов, службы, инструменты)')));
      const days = el('select', { class: 'input' }, [[0, T('бессрочно')], [30, T('30 дней')], [90, T('90 дней')], [365, T('1 год')]].map(([v, t]) => el('option', { value: v }, t)));
      const pw = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const go = el('button', { class: 'btn primary' }, T('Создать'));
      const m = modal(T('Новый токен API'), el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Название')), nm, el('span', { class: 'hint' }, T('Кто будет пользоваться: home-assistant, grafana…'))),
        el('div', { class: 'field' }, el('label', null, T('Права')), role, el('span', { class: 'hint' }, T('Пароли, сеансы, токены, ключи туннелей, перезагрузка и настройки панели недоступны токену никогда.'))),
        el('div', { class: 'field' }, el('label', null, T('Срок')), days),
        el('div', { class: 'field' }, el('label', null, T('Ваш текущий пароль')), pw)), [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), go]);
      go.addEventListener('click', () => busy(go, async () => {
        try {
          const x = await api('/api/token/create', { name: nm.value.trim(), role: role.value, days: +days.value, current: pw.value });
          m.close(); load();
          const box = el('input', { class: 'input mono', readonly: 'readonly', value: x.token });
          const cp = el('button', { class: 'btn primary', onclick: async () => { try { await navigator.clipboard.writeText(x.token); ok(T('Скопировано')); } catch (e) { box.select(); } } }, icon('copy', 'sm'), T('Копировать'));
          modal(T('Токен создан'), el('div', { class: 'stack' },
            el('div', { class: 'alert warn' }, icon('key'), el('div', null, T('Скопируйте токен сейчас: повторно он не показывается. Храните как пароль.'))), box,
            el('p', { class: 'small muted' }, T('Пример: '), el('code', null, 'curl -k -H "Authorization: Bearer ' + x.token.slice(0, 8) + '…" https://' + location.host + '/api/overview'))),
          [cp], { sticky: true });
          setTimeout(() => box.select(), 50);
        } catch (e) { err(e); }
      }));
    } }, icon('plus', 'sm'), T('Создать токен'));
    return card(T('Токены API'), el('div', null, tokHint(el('p', { class: 'muted small' }, T('Для Home Assistant, скриптов и мониторинга: заголовок Authorization: Bearer <токен>. Доступ только из локальной сети.'))),
      el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, tb))), { icon: 'key', flush: true, right: add });
  }
  async function sessionsCard() {
    const tb = el('tbody');
    const idle = el('input', { class: 'input mono', inputmode: 'numeric' });
    const mx = el('input', { class: 'input mono', inputmode: 'numeric' });
    const load = async () => {
      const r = await api('/api/sessions');
      if (document.activeElement !== idle && document.activeElement !== mx) { idle.value = r.idle; mx.value = r.max; }
      replace(tb, r.sessions.map((x) => el('tr', null,
        el('td', null, el('b', null, x.user), x.me ? el('span', { class: 'badge accent' }, T('этот')) : null, el('div', { class: 'small muted' }, (x.ua || '').replace(/\(.*?\)/g, '').slice(0, 60))),
        el('td', null, el('span', { class: 'mono' }, x.ip)),
        el('td', { class: 'nowrap' }, T('вход ') + fmtTime(x.born), el('div', { class: 'small muted' }, T('активность ') + fmtAge(Math.floor(Date.now() / 1000) - x.seen))),
        el('td', { class: 'r' }, x.me ? null : el('button', { class: 'btn sm danger', onclick: async () => { try { await api('/api/session/revoke', { id: x.id }); load(); } catch (e) { err(e); } } }, T('Завершить'))))));
    };
    load().catch(err);
    const all = el('button', { class: 'btn sm', onclick: async () => { try { await api('/api/session/revoke', { id: 'others' }); ok(T('Остальные сеансы завершены')); load(); } catch (e) { err(e); } } }, T('Завершить остальные'));
    // время жизни сеансов (#21)
    const lsave = el('button', { class: 'btn sm' }, T('Сохранить'));
    lsave.addEventListener('click', async () => {
      const pw = await promptPw(T('Время жизни сеансов'), T('Сеансы, вышедшие за новые пределы, закроются (и этот тоже, если он старше).'));
      if (pw == null) return;
      try { ok((await api('/api/sessions/config', { idle: idle.value.trim(), max: mx.value.trim(), current: pw })).msg); load(); } catch (e) { err(e); }
    });
    idle.style.width = mx.style.width = '6em';
    const lim = el('div', { class: 'row wrap small' }, T('Выход без активности через'), idle, T('мин; не дольше'), mx, T('ч с момента входа'), lsave);
    lim.style.padding = '8px 16px';
    return card(T('Активные сеансы'), el('div', null, lim, el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, tb))), { icon: 'key', flush: true, right: all });
  }
