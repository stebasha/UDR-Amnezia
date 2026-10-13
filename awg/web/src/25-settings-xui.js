  // 3x-ui (#30, #32): несколько панелей; туннель AmneziaWG 3.1 — создать, подключить к клиенту, привязать работающий
  const XUI_KIND = { created: 'создан роутером', imported: 'клиент из 3x-ui', linked: 'привязан' };
  function askNamePw(title, text, def) {   // имя нового туннеля + текущий пароль → {name, pw} или null
    return new Promise((res) => {
      let done = false;
      const nm = el('input', { class: 'input mono', value: def || 'awgxui', spellcheck: 'false' });
      const pw = el('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
      const go = () => { done = true; m.close(); res({ name: nm.value.trim(), pw: pw.value }); };
      pw.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
      const m = modal(title, el('div', null, el('p', null, text),
        el('div', { class: 'field' }, el('label', null, T('Имя туннеля')), nm),
        el('div', { class: 'field' }, el('label', null, T('Пароль от этой веб-панели (тот же, что при входе)')), pw)), [
        el('button', { class: 'btn', onclick: () => { done = true; m.close(); res(null); } }, T('Отмена')),
        el('button', { class: 'btn primary', onclick: go }, T('Подключить')),
      ], { onclose: () => { if (!done) res(null); } });
    });
  }
  async function setXui(body) {
    let r;
    try { r = await api('/api/xui'); } catch (e) { err(e); return; }
    let sel = (r.panels.find((p) => p.id === S.xuiPanel) || r.panels[0] || {}).id || '';
    const rerender = () => { S.xuiPanel = sel; clear(body); setXui(body); };
    // ---- панели
    const pick = el('select', { class: 'input' }, r.panels.map((p) => el('option', { value: p.id, selected: p.id === sel }, (p.label || p.id) + ' — ' + p.url)));
    pick.addEventListener('change', () => { sel = pick.value; rerender(); });
    const cur = r.panels.find((p) => p.id === sel);
    const form = (p) => {
      p = p || { id: '', label: '', url: '', token_set: false, insecure: false, host: '', host_default: '' };
      const label = el('input', { class: 'input', value: p.label, placeholder: T('например, Финляндия'), maxlength: 40 });
      const url = el('input', { class: 'input mono', value: p.url, placeholder: 'https://vps.example.com:2053/secretpath', spellcheck: 'false' });
      const tok = el('input', { class: 'input mono', type: 'password', autocomplete: 'off', placeholder: p.token_set ? T('задан — оставьте пустым, чтобы не менять') : T('в 3x-ui: «Учетная запись → Токен API»') });
      const host = el('input', { class: 'input mono', value: p.host, placeholder: p.host_default || 'vps.example.com', spellcheck: 'false' });
      const insec = el('input', { type: 'checkbox', checked: p.insecure });
      const sw = el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, T('Без проверки сертификата')), el('span', null, T('Для самоподписанного сертификата панели 3x-ui.'))),
        el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, insec, el('span', { class: 'knob' }))));
      const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), p.id ? T('Сохранить') : T('Добавить панель'));
      save.addEventListener('click', () => busy(save, async () => {
        try {
          const x = await api('/api/xui', { id: p.id, label: label.value.trim(), url: url.value.trim(), token: tok.value.trim(), host: host.value.trim(), insecure: insec.checked });
          ok(x.msg); sel = x.id; rerender();
        } catch (e) { err(e); }
      }));
      return { save, node: el('div', null,
        el('div', { class: 'form-grid' },
          el('div', { class: 'field' }, el('label', null, T('Название')), label),
          el('div', { class: 'field' }, el('label', null, T('Адрес панели')), url, el('span', { class: 'hint' }, T('Как в браузере, вместе с секретным путём (webBasePath), без /panel'))),
          el('div', { class: 'field' }, el('label', null, T('API-токен')), tok),
          el('div', { class: 'field' }, el('label', null, T('Адрес сервера для туннеля')), host, el('span', { class: 'hint' }, T('Пусто — как в ссылках 3x-ui: узел или адрес панели')))),
        sw) };
    };
    const out = el('div', { class: 'res hidden' });
    const say = (t, good) => { out.textContent = t; out.classList.remove('hidden'); out.classList.toggle('bad', !good); };
    const pf = form(cur);
    const test = el('button', { class: 'btn', disabled: !cur }, icon('activity', 'sm'), T('Проверить подключение'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/xui/test', { id: sel }); ok(T('3x-ui отвечает')); say(x.msg, true); } catch (e) { err(e); say(String(e.message || e), false); } }));
    const addP = el('button', { class: 'btn' }, icon('plus', 'sm'), T('Ещё панель'));
    addP.addEventListener('click', () => {
      const f = form(null);
      const m = modal(T('Новая панель 3x-ui'), f.node, [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), f.save]);
    });
    const delP = el('button', { class: 'btn danger', disabled: !cur }, T('Убрать панель'));
    delP.addEventListener('click', async () => {
      if (!await confirmBox(T('Убрать панель ') + (cur.label || cur.id) + '?', T('Роутер забудет адрес и токен этой панели. В самой 3x-ui ничего не изменится.'), T('Убрать'), true)) return;
      try { ok((await api('/api/xui/panel/remove', { id: sel })).msg); sel = ''; rerender(); } catch (e) { err(e); }
    });
    // ---- туннели через 3x-ui
    const tb = el('tbody');
    const paintTunnels = (list) => replace(tb, list.length ? list.map((t) => el('tr', null,
      el('td', null, el('b', { class: 'mono' }, t.name), el('div', { class: 'small muted' }, (t.panel_label || t.panel) + T(' · подключение №') + t.inbound + (t.email ? ' · ' + t.email : ''))),
      el('td', null, el('span', { class: 'badge' + (t.kind === 'linked' ? ' ok' : '') }, T(XUI_KIND[t.kind] || t.kind))),
      el('td', { class: 'r nowrap' },
        el('button', { class: 'btn sm', title: T('Перенести на роутер параметры подключения из 3x-ui (обфускацию, ключ сервера, порт); ключ роутера не меняется'), onclick: async (e) => {
          const pw = await promptPw(T('Обновить ') + t.name + T(' из 3x-ui?'), T('Если в 3x-ui поменяли параметры обфускации, ключ сервера или порт этого подключения — роутер возьмёт новые. Туннель перезапустится; не поднимется — вернётся прежний конфиг (он же в «Истории»).'));
          if (pw == null) return;
          await busy(e.currentTarget, async () => { try { const x = await api('/api/xui/sync', { name: t.name, current: pw }); (x.ok ? ok : err)(TM(x.msg)); } catch (ex) { err(ex); } });
        } }, T('Обновить из 3x-ui')), ' ',
        el('button', { class: 'btn sm danger', onclick: async () => {
          const txt = t.kind === 'linked' ? T('Роутер забудет связь туннеля с 3x-ui. Сам туннель и подключение в 3x-ui не меняются.')
            : t.kind === 'imported' ? T('Туннель уберётся из сторожа. Клиент в 3x-ui останется.')
              : T('Туннель уберётся из сторожа, подключение «UDR-Amnezia ') + t.name + T('» удалится в 3x-ui.');
          const pw = await promptPw((t.kind === 'linked' ? T('Отвязать ') : T('Убрать туннель ')) + t.name + '?', txt);
          if (pw == null) return;
          try { ok(TM((await api('/api/xui/remove', { name: t.name, current: pw, delete_inbound: true })).msg)); loadT(); loadIb(); } catch (e) { err(e); }
        } }, t.kind === 'linked' ? T('Отвязать') : T('Убрать'))))) : el('tr', null, el('td', { class: 'empty', colspan: 3 }, T('Туннелей через 3x-ui пока нет'))));
    const loadT = async () => { try { paintTunnels((await api('/api/xui')).tunnels); } catch (e) { err(e); } };
    paintTunnels(r.tunnels);
    // ---- подключения AmneziaWG выбранной панели
    const ibBox = el('div', { class: 'stack' }, el('div', { class: 'muted small' }, cur ? T('Загрузка…') : T('Сначала добавьте панель')));
    const loadIb = async () => {
      if (!cur) return;
      let x;
      try { x = await api('/api/xui/inbounds?panel=' + encodeURIComponent(sel)); } catch (e) { replace(ibBox, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, String(e.message || e)))); return; }
      if (!x.inbounds.length) { replace(ibBox, el('div', { class: 'muted small' }, T('В этой панели подключений AmneziaWG нет — создайте туннель ниже'))); return; }
      replace(ibBox, x.inbounds.map((ib) => {
        const linkBtn = ib.match && !ib.tunnels.includes(ib.match) ? el('button', { class: 'btn sm primary', onclick: async (e) => {
          await busy(e.currentTarget, async () => { try { ok(TM((await api('/api/xui/link', { panel: sel, inbound: ib.id, name: ib.match })).msg)); loadT(); loadIb(); } catch (ex) { err(ex); } });
        } }, T('Привязать ') + ib.match) : null;
        return el('div', { class: 'fgroup' },
          el('div', { class: 'row wrap' }, el('b', null, '№' + ib.id + ' «' + ib.remark + '»'), el('span', { class: 'mono small' }, (ib.host || '?') + ':' + ib.port),
            el('span', { class: 'badge ' + (ib.enable ? 'ok' : '') }, ib.enable ? T('вкл') : T('выкл')),
            ib.match ? el('span', { class: 'badge ok' }, T('туннель роутера ') + ib.match) : null,
            ib.tunnels.length ? el('span', { class: 'badge' }, T('связан: ') + ib.tunnels.join(', ')) : null, linkBtn),
          el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('tbody', null, ib.clients.map((c) => el('tr', null,
            el('td', null, el('span', { class: 'mono' }, c.email), c.comment ? el('div', { class: 'small muted' }, c.comment) : null),
            el('td', { class: 'mono small' }, c.address),
            el('td', { class: 'small muted nowrap' }, '↓ ' + fmtBytes(c.down) + ' ↑ ' + fmtBytes(c.up)),
            el('td', { class: 'r nowrap' }, c.router ? el('span', { class: 'badge ok' }, T('это роутер'))
              : c.has_key && c.enable ? el('button', { class: 'btn sm', onclick: async () => {
                if (!r.go_ok) { err(T('нужен amneziawg-go v3.x на роутере')); return; }
                const a = await askNamePw(T('Подключить клиента ') + c.email + '?', T('Роутер возьмёт из 3x-ui ключ этого клиента и параметры подключения и добавит дополнительный туннель. Если этим клиентом уже пользуется другое устройство, они будут мешать друг другу — лучше отдельный клиент.'), 'awgxui');
                if (!a) return;
                try { const y = await api('/api/xui/import', { panel: sel, inbound: ib.id, email: c.email, name: a.name, current: a.pw }); (y.ok ? ok : err)(TM(y.msg)); loadT(); loadIb(); } catch (ex) { err(ex); }
              } }, T('Подключить')) : el('span', { class: 'muted small' }, c.enable ? T('ключ не в 3x-ui') : T('выключен')))))))));
      }));
    };
    if (cur) loadIb();
    const reloadIb = el('button', { class: 'btn' }, icon('refresh', 'sm'), T('Обновить список'));
    reloadIb.addEventListener('click', () => busy(reloadIb, loadIb));
    // ---- новый туннель
    const name = el('input', { class: 'input mono', value: 'awgxui', spellcheck: 'false' });
    const port = el('input', { class: 'input mono', inputmode: 'numeric', placeholder: T('свободный — выберется сам') });
    const mk = el('button', { class: 'btn primary', disabled: !r.go_ok || !cur }, icon('plus', 'sm'), T('Создать туннель'));
    mk.addEventListener('click', async () => {
      const pw = await promptPw(T('Создать туннель через 3x-ui?'), T('В 3x-ui появится подключение AmneziaWG 3.1 «UDR-Amnezia …» с одним клиентом — роутером (его закрытый ключ остаётся на роутере). Туннель добавится дополнительным; сторож будет использовать его по порядку приоритета.'));
      if (pw == null) return;
      await busy(mk, async () => {
        try { const x = await api('/api/xui/create', { panel: sel, name: name.value.trim(), port: port.value.trim(), current: pw }); (x.ok ? ok : err)(TM(x.msg)); say(TM(x.msg), x.ok); loadT(); loadIb(); } catch (e) { err(e); say(String(e.message || e), false); }
      });
    });
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Панели 3x-ui'), el('div', null,
          el('p', { class: 'muted small' }, T('3x-ui ≥ 3.8.5 умеет AmneziaWG 3.1. Нужен API-токен с областью admin: в 3x-ui «Учетная запись → Токен API». Токены хранятся на роутере (файл 600) и в браузер не возвращаются. Панелей может быть несколько.')),
          r.panels.length > 1 ? el('div', { class: 'field' }, el('label', null, T('Панель')), pick) : null,
          pf.node, out), { icon: 'server', foot: [test, pf.save, addP, cur ? delP : null] }),
        card(T('Новый туннель AmneziaWG 3.1'), el('div', null,
          r.go_ok ? null : el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('На роутере amneziawg-go ') + (r.go || '?') + T(': для AmneziaWG 3.1 нужен v3.x. Обновите: «Система и обновление → Проверить AmneziaWG → Обновить на роутере».'))),
          el('p', { class: 'muted small' }, T('Роутер создаст в выбранной панели отдельное подключение со своим клиентом.')),
          el('div', { class: 'form-grid' },
            el('div', { class: 'field' }, el('label', null, T('Имя туннеля')), name),
            el('div', { class: 'field' }, el('label', null, T('Порт UDP в 3x-ui')), port, el('span', { class: 'hint' }, T('Откройте его в файрволе сервера'))))), { icon: 'tunnel', foot: mk })),
      card(T('Подключения AmneziaWG в панели'), el('div', null,
        el('p', { class: 'muted small' }, T('Туннель роутера, который уже ведёт на подключение (совпали ключ сервера и порт), можно привязать — тогда «Обновить из 3x-ui» переносит на роутер параметры, изменённые в 3x-ui. Клиента, ключ которого хранит 3x-ui, можно подключить новым туннелем.')),
        ibBox), { icon: 'globe', foot: reloadIb }),
      card(T('Туннели через 3x-ui'), el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, tb)), { icon: 'tunnel', flush: true })]);
  }
