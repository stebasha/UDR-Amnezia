  // маршруты (#22): разные туннели для разных устройств и доменов — свой профиль PBR UniFi, своя цепочка туннелей
  function chainPicker(all, cur, lab) {   // цепочка туннелей по приоритету: нажать туннель — добавить в конец, нажать в цепочке — убрать
    const chain = (cur || []).slice();
    const box = el('div', { class: 'stack' });
    const paint = () => {
      replace(box,
        el('div', { class: 'row wrap' }, el('span', { class: 'small muted' }, T('Порядок:')), chain.length ? chain.map((t, i) => el('button', { class: 'btn sm primary', title: T('Убрать из цепочки'),
          onclick: () => { chain.splice(i, 1); paint(); } }, (i + 1) + '. ' + lab(t), icon('x', 'sm'))) : el('span', { class: 'small muted' }, T('выберите туннели ниже'))),
        el('div', { class: 'row wrap' }, el('span', { class: 'small muted' }, T('Добавить:')), all.filter((t) => !chain.includes(t)).map((t) => el('button', { class: 'btn sm',
          onclick: () => { chain.push(t); paint(); } }, icon('plus', 'sm'), lab(t)))));
    };
    paint();
    return { node: box, value: () => chain.slice() };
  }
  async function setRoutes(body) {
    let r;
    try { r = await api('/api/routes'); } catch (e) { err(e); return; }
    const lab = (t) => (r.labels && r.labels[t] ? r.labels[t] + ' (' + t + ')' : t);
    const reload = () => { clear(body); setRoutes(body); };
    const tb = el('tbody', null, r.routes.map((x) => {
      const main = x.id === 'main';
      const sw = main ? null : el('select', { class: 'input sm', onchange: async (e) => {
        try { ok(TM((await api('/api/route/switch', { id: x.id, tunnel: e.target.value })).msg)); setTimeout(reload, 2500); } catch (ex) { err(ex); }
      } }, el('option', { value: 'auto', selected: !x.forced }, T('Авто')), x.tunnels.map((t) => el('option', { value: t, selected: x.forced === t }, lab(t))));
      const edit = main ? null : el('button', { class: 'btn sm', onclick: () => {
        const cp = chainPicker(r.tunnels, x.tunnels, lab);
        const lb = el('input', { class: 'input', value: x.label || '', maxlength: 40 });
        const only = el('input', { type: 'checkbox', checked: x.only });
        const save = el('button', { class: 'btn primary' }, T('Сохранить'));
        const m = modal(T('Маршрут ') + x.id, el('div', { class: 'stack' },
          el('div', { class: 'field' }, el('label', null, T('Название')), lb),
          el('div', { class: 'field' }, el('label', null, T('Туннели по приоритету')), cp.node),
          el('label', { class: 'row' }, only, T('Эти туннели — только для этого маршрута (основной их не использует)'))), [el('button', { class: 'btn', onclick: () => m.close() }, T('Отмена')), save]);
        save.addEventListener('click', async () => {
          const pw = await promptPw(T('Сохранить маршрут ') + x.id + '?', T('Сторож маршрута перезапустится: трафик этого профиля на секунды уйдёт в blackhole (не в WAN).'));
          if (pw == null) return;
          try { ok(TM((await api('/api/route/save', { id: x.id, tunnels: cp.value(), label: lb.value.trim(), only: only.checked, current: pw })).msg)); m.close(); reload(); } catch (e) { err(e); }
        });
      } }, T('Изменить'));
      const del = main ? null : el('button', { class: 'btn sm danger', onclick: async () => {
        const pw = await promptPw(T('Убрать маршрут ') + x.id + '?', T('Трафик профиля ') + x.rail + T(' пойдёт как без набора — в сам профиль VPN Client UniFi. Туннели остаются.'));
        if (pw == null) return;
        try { ok(TM((await api('/api/route/remove', { id: x.id, current: pw })).msg)); reload(); } catch (e) { err(e); }
      } }, T('Убрать'));
      return el('tr', null,
        el('td', null, el('b', null, main ? T('Основной') : (x.label || x.id)), el('div', { class: 'small muted mono' }, (main ? '' : x.id + ' · ') + (x.rail || '?') + T(' · таблица ') + (x.table || '?'))),
        el('td', null, el('div', { class: 'row wrap' }, x.tunnels.map((t, i) => el('span', { class: 'badge' + (t === x.active ? ' ok' : '') }, (i + 1) + '. ' + lab(t))))),
        el('td', null, el('span', { class: 'badge ' + (x.service === 'active' ? 'ok' : 'crit') }, x.service === 'active' ? T('сторож работает') : T('сторож не запущен')),
          x.forced ? el('div', { class: 'small muted' }, T('выбран вручную: ') + x.forced) : null),
        el('td', { class: 'r nowrap' }, main ? el('a', { class: 'btn sm', href: '#/tunnels' }, T('Туннели')) : [sw, ' ', edit, ' ', del]));
    }));
    const free = r.rails.filter((x) => !x.used);
    const rail = el('select', { class: 'input' }, free.map((x) => el('option', { value: x.rail }, x.rail + T(' (таблица ') + x.table + ')')));
    const rid = el('input', { class: 'input mono', placeholder: 'us', maxlength: 12, spellcheck: 'false' });
    const lb = el('input', { class: 'input', placeholder: T('например, США для ТВ'), maxlength: 40 });
    const cp = chainPicker(r.tunnels, [], lab);
    const only = el('input', { type: 'checkbox' });
    const mk = el('button', { class: 'btn primary', disabled: !free.length }, icon('plus', 'sm'), T('Создать маршрут'));
    mk.addEventListener('click', async () => {
      if (!cp.value().length) { err(T('выберите туннели маршрута по порядку')); return; }
      const pw = await promptPw(T('Создать маршрут?'), T('Устройства и домены, которые в UniFi направлены на профиль ') + rail.value + T(', пойдут через выбранные туннели со своим сторожем и kill switch.'));
      if (pw == null) return;
      await busy(mk, async () => {
        try { ok(TM((await api('/api/route/save', { new: true, id: rid.value.trim(), rail: rail.value, tunnels: cp.value(), label: lb.value.trim(), only: only.checked, current: pw })).msg)); reload(); } catch (e) { err(e); }
      });
    });
    add(body, [
      el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Какие устройства и домены куда идут, задаётся в UniFi: Settings → Routing → Policy-Based Routes, правило на нужный профиль VPN Client. Здесь каждому профилю назначается своя цепочка туннелей AmneziaWG со своим переключением и kill switch. Профиль для нового маршрута — ещё один VPN Client в UniFi (как для основного) и хотя бы одно правило PBR на него.'))),
      card(T('Маршруты'), el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
        el('thead', null, el('tr', null, el('th', null, T('Маршрут')), el('th', null, T('Туннели (активный выделен)')), el('th', null, T('Состояние')), el('th', { class: 'r' }, ''))), tb)),
      { icon: 'layers', flush: true }),
      card(T('Новый маршрут'), el('div', { class: 'stack' },
        free.length ? null : el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('Свободных профилей VPN Client с правилами PBR нет. Создайте в UniFi ещё один VPN Client и правило Policy-Based Route на него, затем обновите страницу.'))),
        el('div', { class: 'form-grid' },
          el('div', { class: 'field' }, el('label', null, T('Профиль VPN Client UniFi')), rail),
          el('div', { class: 'field' }, el('label', null, T('ID')), rid, el('span', { class: 'hint' }, T('латиница, до 12 знаков'))),
          el('div', { class: 'field' }, el('label', null, T('Название')), lb)),
        el('div', { class: 'field' }, el('label', null, T('Туннели по приоритету')), cp.node),
        el('label', { class: 'row' }, only, T('Эти туннели — только для этого маршрута (основной их не использует)'))), { icon: 'plus', foot: mk })]);
  }
