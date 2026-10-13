  // журнал действия на VPS (awg-vps-job): обновлять, пока идёт; итог — по «[код N]» в конце
  async function followVpsJob(box) {
    box.classList.remove('hidden');
    for (let i = 0; i < 400; i++) {
      let x;
      try { x = await api('/api/vps/job'); } catch (e) { await new Promise((ok2) => setTimeout(ok2, 3000)); continue; }
      paint(box, x.text); box.scrollTop = box.scrollHeight;
      if (!x.running) {
        const good = /\[код 0\]/.test(x.text);
        (good ? ok : err)(good ? T('Готово') : T('Не удалось — подробности в журнале ниже'));
        return good;
      }
      await new Promise((ok2) => setTimeout(ok2, 3000));
    }
    return false;
  }
  // свой VPS (#13): состояние сервера, обновление AmneziaWG, смена ключей и обфускации на обеих сторонах с откатом
  async function setVps(body) {
    let r;
    try { r = await api('/api/vps'); } catch (e) { err(e); return; }
    const host = el('input', { class: 'input mono', value: r.host, placeholder: r.host_default || '203.0.113.10', spellcheck: 'false' });
    const port = el('input', { class: 'input mono', value: r.port, inputmode: 'numeric' });
    const user = el('input', { class: 'input mono', value: r.user, spellcheck: 'false' });
    const out = el('div', { class: 'out hidden' });
    const show = (text) => { paint(out, text); out.classList.remove('hidden'); };
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => { try { ok((await api('/api/vps', { host: host.value.trim(), port: port.value.trim(), user: user.value.trim() })).msg); } catch (e) { err(e); } }));
    const test = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Проверить подключение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/vps/test', {}); (x.ok ? ok : err)(x.ok ? T('VPS доступен') : T('VPS недоступен')); show(x.msg); } catch (e) { err(e); } }));
    const st = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Состояние сервера'));
    st.addEventListener('click', () => busy(st, async () => { try { const x = await api('/api/vps/status', {}); show(x.text); } catch (e) { err(e); } }));
    const ver = el('button', { class: 'btn' }, icon('refresh', 'sm'), T('Проверить версии'));
    ver.addEventListener('click', () => busy(ver, async () => { try { const x = await api('/api/vps/versions', {}); show(x.text); if (x.update) toast(T('На VPS есть что обновить')); } catch (e) { err(e); } }));
    const log = el('div', { class: 'out' + (r.log ? '' : ' hidden') });
    if (r.log) paint(log, r.log);
    const btns = [];
    async function follow() {
      btns.forEach((b) => { b.disabled = true; });
      await followVpsJob(log);
      btns.forEach((b) => { b.disabled = false; });
    }
    const lab = (n) => { const t = S.ov && S.ov.tunnels.find((x) => x.name === n); return t && t.label ? t.label + ' (' + n + ')' : n; };
    const tun = el('select', { class: 'input' }, r.tunnels.map((t) => el('option', { value: t }, lab(t))));
    const job = (action, title, text) => {
      const b = el('button', { class: 'btn' + (action === 'update' ? '' : ' danger') }, title);
      b.addEventListener('click', async () => {
        const pw = await promptPw(title + '?', text);
        if (pw == null) return;
        try { ok((await api('/api/vps/run', { action, tunnel: tun.value, current: pw })).msg); follow(); } catch (e) { err(e); }
      });
      btns.push(b);
      return b;
    };
    // мастер (#28): от пароля VPS до работающего туннеля
    const vpw = el('input', { class: 'input', type: 'password', autocomplete: 'off', placeholder: r.key ? T('не нужен, если ключ роутера уже на VPS') : T('пароль root на VPS — один раз') });
    const tname = el('input', { class: 'input mono', value: 'awgvps', spellcheck: 'false' });
    const aport = el('input', { class: 'input mono', value: '51823', inputmode: 'numeric' });
    const wiz = el('button', { class: 'btn primary' }, icon('server', 'sm'), T('Подключить и настроить'));
    wiz.addEventListener('click', async () => {
      if (!host.value.trim() && !r.host_default) { err(T('укажите адрес VPS')); host.focus(); return; }
      const pw = await promptPw(T('Подключить VPS?'), T('Роутер войдёт на VPS (пароль VPS — только для первого входа, не сохраняется), положит туда свой ключ, соберёт AmneziaWG из исходников amnezia-vpn (3–7 минут), создаст сервер и добавит туннель. Нужны Ubuntu или Debian и root. Существующие туннели не трогаются.'));
      if (pw == null) return;
      try {
        ok((await api('/api/vps/run', { action: 'setup', host: host.value.trim(), port: port.value.trim(), user: user.value.trim(), vps_password: vpw.value,
          name: tname.value.trim(), awg_port: aport.value.trim(), current: pw })).msg);
        vpw.value = '';
        await follow();
        r = await api('/api/vps');
      } catch (e) { err(e); }
    });
    btns.push(wiz);
    const akey = el('button', { class: 'btn' }, icon('key', 'sm'), T('Добавить ключ роутера'));
    akey.addEventListener('click', async () => {
      if (!vpw.value) { err(T('введите пароль VPS')); vpw.focus(); return; }
      const pw = await promptPw(T('Добавить ключ роутера на VPS?'), T('Для VPS, где сервер уже настроен: роутер войдёт по паролю один раз и добавит свой ключ в ~/.ssh/authorized_keys. Дальше обновление, состояние, ключи и обфускация — без пароля. Сервер не меняется.'));
      if (pw == null) return;
      try {
        ok((await api('/api/vps/run', { action: 'addkey', host: host.value.trim(), port: port.value.trim(), user: user.value.trim(), vps_password: vpw.value, current: pw })).msg);
        vpw.value = '';
        await follow();
      } catch (e) { err(e); }
    });
    btns.push(akey);
    const upd = job('update', T('Обновить AmneziaWG на VPS'), T('Последние релизы amnezia-vpn собираются на VPS из исходников (3–7 минут), сервер перезапускается. Если туннели к VPS не получат handshake — вернутся прежние файлы.'));
    const rk = job('rotate-keys', T('Сменить ключи'), T('Новые ключи сервера и роутера одновременно. Туннель будет недоступен 10–30 секунд (kill switch держит трафик). Не заработает — обе стороны откатятся.'));
    const ob = job('obfs', T('Новые параметры обфускации'), T('Новые Jc, Jmin, Jmax, S1, S2, H1–H4 на VPS и роутере одновременно — если провайдер начал узнавать трафик. Туннель будет недоступен 10–30 секунд; не заработает — откат.'));
    const noTun = !r.tunnels.length;
    if (noTun) { rk.disabled = true; ob.disabled = true; }
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Подключение к VPS'), el('div', null,
          el('p', { class: 'muted small' }, T('Роутер входит на ваш VPS по SSH своим ключом, без пароля. Новый VPS: укажите адрес и пароль root один раз и нажмите «Подключить и настроить» — роутер сам добавит ключ, соберёт AmneziaWG, создаст сервер и туннель.')),
          el('div', { class: 'row wrap' }, el('span', { class: 'badge ' + (r.key ? 'ok' : 'warn') }, r.key ? T('ключ роутера есть') : T('ключа роутера нет'))),
          el('div', { class: 'form-grid' },
            el('div', { class: 'field' }, el('label', null, T('Адрес VPS')), host, el('span', { class: 'hint' }, r.host_default ? T('Пусто — ваш VPS из настройки: ') + r.host_default : T('IP или имя сервера'))),
            el('div', { class: 'field' }, el('label', null, T('Порт SSH')), port),
            el('div', { class: 'field' }, el('label', null, T('Пользователь')), user),
            el('div', { class: 'field' }, el('label', null, T('Пароль VPS')), vpw),
            el('div', { class: 'field' }, el('label', null, T('Имя нового туннеля')), tname),
            el('div', { class: 'field' }, el('label', null, T('Порт AmneziaWG (UDP)')), aport, el('span', { class: 'hint' }, T('Откройте его в файрволе хостера')))),
          r.pub ? el('details', { class: 'fgroup' }, el('summary', null, T('Открытый ключ роутера (для ~/.ssh/authorized_keys на VPS)')), el('pre', { class: 'res' }, r.pub)) : null,
          out, log), { icon: 'server', foot: [test, save, akey, wiz] }),
        card(T('Сервер и AmneziaWG'), el('div', null,
          el('p', { class: 'muted small' }, T('Состояние — только чтение: служба awg-server, handshake роутера, NAT, файрвол, права на ключи, нагрузка и место. Обновление — только из официальных исходников amnezia-vpn.'))),
        { icon: 'activity', foot: [st, ver, upd] })),
      card(T('Ключи и обфускация'), el('div', null,
        el('p', { class: 'muted small' }, noTun ? T('Нет туннеля, у которого Endpoint — этот VPS: менять можно только свой сервер, не сервер провайдера.')
          : T('Меняется туннель к вашему VPS одновременно на обеих сторонах; перед изменением делаются копии, при неудаче всё откатывается само.')),
        noTun ? null : el('div', { class: 'field' }, el('label', null, T('Туннель')), tun)), { icon: 'key', foot: [rk, ob] })]);
    if (r.running) follow();
  }
  // Home Assistant (#5): MQTT discovery — HA сам находит устройство, датчики, выбор канала и кнопки
  async function setHa(body) {
    let r;
    try { r = await api('/api/ha'); } catch (e) { err(e); return; }
    const host = el('input', { class: 'input mono', value: r.host, placeholder: '192.168.1.10', spellcheck: 'false' });
    const port = el('input', { class: 'input mono', value: r.port, inputmode: 'numeric' });
    const user = el('input', { class: 'input mono', value: r.user, autocomplete: 'off', spellcheck: 'false' });
    const pass = el('input', { class: 'input', type: 'password', autocomplete: 'new-password', placeholder: r.pass_set ? T('задан — оставьте пустым, чтобы не менять') : '' });
    const tls = el('select', { class: 'input' }, el('option', { value: 'no' }, T('без TLS (1883)')), el('option', { value: 'yes' }, T('TLS с проверкой сертификата (8883)')), el('option', { value: 'insecure' }, T('TLS без проверки (самоподписанный)')));
    tls.value = r.tls;
    const prefix = el('input', { class: 'input mono', value: r.prefix });
    const interval = el('input', { class: 'input mono', value: r.interval, inputmode: 'numeric' });
    const en = el('input', { type: 'checkbox', checked: r.enabled || !r.host });
    const rb = el('input', { type: 'checkbox', checked: r.allow_reboot });
    const logBox = el('pre', { class: 'res' + (r.log ? '' : ' hidden') }, r.log || '');
    const sw = (inp, t, h) => el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, t), el('span', null, h)), el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }))));
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/ha', { host: host.value.trim(), port: port.value.trim(), user: user.value.trim(), pass: pass.value, tls: tls.value,
          prefix: prefix.value.trim(), interval: interval.value.trim(), allow_reboot: rb.checked, enabled: en.checked });
        (x.ok ? ok : err)(x.msg); pass.value = '';
      } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Проверить подключение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/ha/test', {}); (x.ok ? ok : err)(x.msg); logBox.textContent = x.msg; logBox.classList.remove('hidden'); } catch (e) { err(e); } }));
    body.appendChild(card('Home Assistant', el('div', null,
      el('div', { class: 'row wrap' }, el('span', { class: 'badge ' + (r.active ? 'ok' : '') }, r.active ? T('работает') : r.enabled ? T('не работает') : T('выкл'))),
      el('p', { class: 'muted small' }, T('Через MQTT discovery: в Home Assistant с интеграцией MQTT появится устройство «UDR-Amnezia» — активный канал, связь, handshake, RTT, потери и трафик туннелей, kill switch, процессор, память, температура; выбор канала (авто или туннель) и перезапуск туннелей.')),
      el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Брокер MQTT')), host, el('span', { class: 'hint' }, T('Адрес Mosquitto или брокера Home Assistant в LAN'))),
        el('div', { class: 'field' }, el('label', null, T('Порт')), port),
        el('div', { class: 'field' }, el('label', null, T('Логин')), user),
        el('div', { class: 'field' }, el('label', null, T('Пароль')), pass),
        el('div', { class: 'field' }, el('label', null, 'TLS'), tls),
        el('div', { class: 'field' }, el('label', null, T('Префикс discovery')), prefix, el('span', { class: 'hint' }, T('Как в настройках MQTT в HA (обычно homeassistant)'))),
        el('div', { class: 'field' }, el('label', null, T('Период, с')), interval, el('span', { class: 'hint' }, T('Как часто отправлять состояние: 10–600')))),
      sw(en, T('Служба awg-ha'), T('Публикует состояние и принимает команды из Home Assistant.')),
      sw(rb, T('Кнопка «Перезагрузить роутер» в HA'), T('Выключено по умолчанию: любой, кто может писать в брокер MQTT, сможет перезагрузить роутер.')),
      logBox), { icon: 'activity', foot: [test, save] }));
  }
