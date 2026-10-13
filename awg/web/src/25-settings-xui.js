  // 3x-ui (#30): туннель AmneziaWG 3.1 через API панели 3x-ui по токену
  async function setXui(body) {
    let r;
    try { r = await api('/api/xui'); } catch (e) { err(e); return; }
    const url = el('input', { class: 'input mono', value: r.url, placeholder: 'https://vps.example.com:2053/secretpath', spellcheck: 'false' });
    const tok = el('input', { class: 'input mono', type: 'password', autocomplete: 'off', placeholder: r.token_set ? T('задан — оставьте пустым, чтобы не менять') : T('в 3x-ui: «Учетная запись → Токен API»') });
    const host = el('input', { class: 'input mono', value: r.host, placeholder: r.host_default || 'vps.example.com', spellcheck: 'false' });
    const insec = el('input', { type: 'checkbox', checked: r.insecure });
    const out = el('div', { class: 'res hidden' });
    const say = (t, good) => { out.textContent = t; out.classList.remove('hidden'); out.classList.toggle('bad', !good); };
    const sw = (inp, t, h) => el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, t), el('span', null, h)), el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }))));
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      try { ok((await api('/api/xui', { url: url.value.trim(), token: tok.value.trim(), host: host.value.trim(), insecure: insec.checked })).msg); tok.value = ''; r.token_set = true; } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Проверить подключение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/xui/test', {}); ok(T('3x-ui отвечает')); say(x.msg, true); } catch (e) { err(e); say(String(e.message || e), false); } }));
    const name = el('input', { class: 'input mono', value: 'awgxui', spellcheck: 'false' });
    const port = el('input', { class: 'input mono', inputmode: 'numeric', placeholder: T('свободный — выберется сам') });
    const mk = el('button', { class: 'btn primary', disabled: !r.go_ok }, icon('plus', 'sm'), T('Создать туннель'));
    mk.addEventListener('click', async () => {
      const pw = await promptPw(T('Создать туннель через 3x-ui?'), T('В 3x-ui появится подключение AmneziaWG 3.1 «UDR-Amnezia …» с одним клиентом — роутером (его закрытый ключ остаётся на роутере). Туннель добавится дополнительным; сторож будет использовать его по порядку приоритета.'));
      if (pw == null) return;
      await busy(mk, async () => {
        try { const x = await api('/api/xui/create', { name: name.value.trim(), port: port.value.trim(), current: pw }); (x.ok ? ok : err)(x.msg); say(x.msg, x.ok); load(); } catch (e) { err(e); say(String(e.message || e), false); }
      });
    });
    const tb = el('tbody');
    const load = async () => {
      const x = await api('/api/xui');
      replace(tb, x.tunnels.length ? x.tunnels.map((t) => el('tr', null,
        el('td', null, el('b', { class: 'mono' }, t.name), el('div', { class: 'small muted' }, T('подключение 3x-ui №') + t.inbound + ' · ' + t.host + ':' + t.port)),
        el('td', { class: 'small' }, fmtTime(t.created, true)),
        el('td', { class: 'r' }, el('button', { class: 'btn sm danger', onclick: async () => {
          const pw = await promptPw(T('Убрать туннель ') + t.name + '?', T('Туннель уберётся из сторожа, подключение «UDR-Amnezia ') + t.name + T('» удалится в 3x-ui.'));
          if (pw == null) return;
          try { ok((await api('/api/xui/remove', { name: t.name, current: pw, delete_inbound: true })).msg); load(); } catch (e) { err(e); }
        } }, T('Убрать'))))) : el('tr', null, el('td', { class: 'empty', colspan: 3 }, T('Туннелей через 3x-ui пока нет'))));
    };
    load().catch(err);
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Панель 3x-ui'), el('div', null,
          el('p', { class: 'muted small' }, T('3x-ui ≥ 3.8.5 на вашем сервере умеет AmneziaWG 3.1. Нужен API-токен с областью admin: в 3x-ui «Учетная запись → Токен API». Токен хранится на роутере (файл 600) и в браузер не возвращается.')),
          el('div', { class: 'form-grid' },
            el('div', { class: 'field' }, el('label', null, T('Адрес панели')), url, el('span', { class: 'hint' }, T('Как в браузере, вместе с секретным путём (webBasePath), без /panel'))),
            el('div', { class: 'field' }, el('label', null, T('API-токен')), tok),
            el('div', { class: 'field' }, el('label', null, T('Адрес сервера для туннеля')), host, el('span', { class: 'hint' }, T('Пусто — узел из адреса панели')))),
          sw(insec, T('Без проверки сертификата'), T('Для самоподписанного сертификата панели 3x-ui.')),
          out), { icon: 'server', foot: [test, save] }),
        card(T('Туннель AmneziaWG 3.1'), el('div', null,
          r.go_ok ? null : el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('На роутере amneziawg-go ') + (r.go || '?') + T(': для AmneziaWG 3.1 нужен v3.x. Обновите: «Система и обновление → Проверить AmneziaWG → Обновить на роутере».'))),
          el('div', { class: 'form-grid' },
            el('div', { class: 'field' }, el('label', null, T('Имя туннеля')), name),
            el('div', { class: 'field' }, el('label', null, T('Порт UDP в 3x-ui')), port, el('span', { class: 'hint' }, T('Откройте его в файрволе сервера')))),
          el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, tb))), { icon: 'tunnel', foot: mk }))]);
  }
