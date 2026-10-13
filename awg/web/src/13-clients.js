  // ===================================================================== КЛИЕНТЫ
  function clientsTable(list, compact) {
    if (!list.length) return el('div', { class: 'empty' }, T('Сейчас через туннель никто не ходит (или conntrack недоступен)'));
    return el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' },
      el('thead', null, el('tr', null, el('th', null, T('Устройство')), el('th', null, 'IP'), compact ? null : el('th', null, 'MAC'), el('th', null, T('Туннель')),
        el('th', { class: 'r' }, T('Соединений')), compact ? null : el('th', { class: 'r' }, T('Трафик')), compact ? null : el('th', null, T('Куда чаще всего')))),
      el('tbody', null, list.map((c) => el('tr', null,
        el('td', null, el('span', { class: 'row' }, el('span', { class: 'cav' }, icon('laptop', 'sm')), el('b', null, c.name || T('без имени')))),
        el('td', null, el('span', { class: 'mono' }, c.ip)),
        compact ? null : el('td', null, el('span', { class: 'mono small muted' }, c.mac || '—')),
        el('td', null, el('span', { class: 'badge accent' }, c.tunnel)),
        el('td', { class: 'r' }, c.conns),
        compact ? null : el('td', { class: 'r nowrap' }, c.bytes ? fmtBytes(c.bytes) : '—'),
        compact ? null : el('td', { class: 'mono small muted' }, c.top.join(', ')))))));
  }
  PAGES.clients = function (main) {
    const box = el('div');
    const q = el('input', { class: 'input', placeholder: T('поиск по имени, IP, MAC'), spellcheck: 'false' });
    q.style.maxWidth = '260px'; q.style.height = '30px';
    const sum = el('span', { class: 'muted small' });
    let data = { clients: [] };
    const show = () => {
      const f = q.value.trim().toLowerCase();
      replace(box, clientsTable(data.clients.filter((c) => !f || (c.name + ' ' + c.ip + ' ' + c.mac).toLowerCase().includes(f)), false));
      replace(sum, data.clients.length + T(' устр. · ') + data.total + T(' соединений'));
    };
    q.addEventListener('input', show);
    add(main, [head(T('Клиенты в туннеле')),
      el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Устройства LAN, чьи соединения сейчас идут через туннели (по таблице conntrack: метка PBR '), el('code', null, '—'), T(' или адрес туннеля). Кто попадает в туннель, задаётся правилами PBR в UniFi и доменами в «Маршрутизации».'))),
      el('div', { class: 'spacer' }),
      el('section', { class: 'card' }, el('div', { class: 'hd' }, icon('users'), el('h2', null, T('Сейчас')), sum, q), box)]);
    every(5000, async () => {
      data = await api('/api/clients');
      const c = main.querySelector('.alert.info code'); if (c) c.textContent = data.mark || '—';
      show();
    });
  };

