  async function setSystem(body) {
    let r;
    try { r = await api('/api/system'); } catch (e) { err(e); return; }
    const upd = el('div');
    const log = el('div', { class: 'out hidden' });
    const chk = el('button', { class: 'btn' }, icon('refresh', 'sm'), T('Проверить обновления'));
    // канал обновлений (#8): stable — релизы с проверкой SHA256, beta — ветка main, своя ветка — для проверки до слияния
    const chanLabel = (u) => (u.channel === 'stable' ? T('канал stable') + (u.kind === 'tag' ? ', ' + T('релиз ') + u.ref : ', ' + T('релизов нет — ветка main'))
      : u.channel === 'beta' ? T('канал beta, ветка main') : T('ветка ') + u.branch);
    const chSel = el('select', { class: 'input', 'aria-label': T('Канал обновлений') },
      el('option', { value: 'stable' }, T('stable — проверенные релизы')), el('option', { value: 'beta' }, T('beta — ветка main')));
    chSel.style.width = 'auto';
    if (r.channel === 'branch') chSel.appendChild(el('option', { value: 'branch' }, T('ветка ') + r.branch));
    chSel.value = r.channel || 'stable';
    chSel.addEventListener('change', async () => {
      if (chSel.value === 'branch') return;
      try { ok((await api('/api/update/channel', { channel: chSel.value })).msg); replace(upd); } catch (e) { err(e); }
    });
    async function followUpdate() {
      log.classList.remove('hidden');
      let lost = 0;
      for (let i = 0; i < 600; i++) {
        await new Promise((ok2) => setTimeout(ok2, 2000));
        try {
          const x = await api('/api/update/log');
          paint(log, x.text); log.scrollTop = log.scrollHeight;
          if (lost) { lost = 0; toast(T('Панель снова на связи')); }
          if (!x.running && i > 2) {
            const good = /\[код 0\]/.test(x.text);
            replace(upd, el('div', { class: 'alert ' + (good ? 'ok' : 'crit') }, icon(good ? 'okc' : 'alert'), el('div', null,
              good ? T('Обновление завершено: версия ') + x.version + T('. Страница перезагрузится.') : T('Обновление завершилось с ошибкой (при сбое выполнен откат). Журнал — ниже и в «Журналах → Обновление».'))));
            if (good) setTimeout(() => location.reload(), 4000);
            return;
          }
        } catch (e) {
          lost++;
          if (lost === 1) replace(upd, el('div', { class: 'alert info' }, el('span', { class: 'spinner sm' }), el('div', null, T('Панель перезапускается после обновления — жду, когда она вернётся…'))));
        }
      }
    }
    chk.addEventListener('click', () => busy(chk, async () => {
      try {
        const u = await api('/api/update/check', {});
        if (u.running) { replace(upd, el('div', { class: 'alert info' }, icon('info'), el('div', null, T('Обновление уже идёт.')))); followUpdate(); return; }
        const go = el('button', { class: 'btn primary' }, icon('download', 'sm'), T('Обновить до ') + u.latest);
        go.addEventListener('click', async () => {
          if (!await confirmBox(T('Обновить до ') + u.latest + '?', T('Перед обновлением делается копия скриптов. Службы перезапустятся (несколько секунд без трафика PBR). Если после обновления сторож, маршрут или панель не заработают — автоматически вернётся прежняя версия.'), T('Обновить'))) return;
          try { ok((await api('/api/update/run', {})).msg); go.disabled = true; followUpdate(); } catch (e) { err(e); }
        });
        replace(upd, u.latest ? (u.update ? el('div', null, el('div', { class: 'alert info' }, icon('download'), el('div', null, T('Доступна версия '), el('b', null, u.latest), T(' (у вас ') + u.current + ', ' + chanLabel(u) + ').')),
          u.notes ? el('details', { class: 'fgroup' }, el('summary', null, T('Что нового')), el('pre', { class: 'res' }, u.notes)) : null,
          el('div', { class: 'spacer' }), go, el('div', { class: 'small muted' }, T('Или по SSH: '), el('code', null, u.cmd)))
          : u.older ? el('div', null, el('div', { class: 'alert info' }, icon('info'), el('div', null, T('У вас ') + u.current + T(' — новее, чем в выбранном канале (') + chanLabel(u) + ', ' + u.latest + T('). Обновлять нечего; откат на старую версию — только вручную по SSH: '), el('code', null, u.cmd))))
          : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, T('Установлена последняя версия ') + u.current + ' (' + chanLabel(u) + ').')))
          : el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('Не удалось узнать последнюю версию в ') + u.repo + T(' (GitHub недоступен с роутера?)'))));
      } catch (e) { err(e); }
    }));
    // бинарники AmneziaWG против последних официальных релизов amnezia-vpn (#11); обновление из панели (#29)
    const bup = el('div');
    const blog = el('div', { class: 'out hidden' });
    const binsUpdateBtn = () => {
      const go = el('button', { class: 'btn primary' }, icon('download', 'sm'), T('Обновить на роутере'));
      go.addEventListener('click', async () => {
        const pw = await promptPw(T('Обновить AmneziaWG на роутере?'), T('Последние релизы amnezia-vpn собираются на вашем VPS (3–7 минут), затем туннели пересоздаются на новых файлах (несколько секунд без трафика PBR). Если handshake не появится — вернутся прежние файлы.'));
        if (pw == null) return;
        try { ok((await api('/api/vps/run', { action: 'router-bins', current: pw })).msg); go.disabled = true; await followVpsJob(blog); go.disabled = false; } catch (e) { err(e); }
      });
      return el('div', { class: 'row' }, go);
    };
    const bchk = el('button', { class: 'btn' }, icon('refresh', 'sm'), T('Проверить AmneziaWG'));
    bchk.addEventListener('click', () => busy(bchk, async () => {
      try {
        const b = await api('/api/bins/check', { force: true });
        const row = (x) => el('li', null, el('b', null, x.name), ': ' + (x.installed || T('версия не определяется')) + ' → ',
          x.state === 'unknown' ? T('релиз не узнать') : x.state === 'ok' ? T('последняя ') + x.latest : el('b', null, x.latest), ' ',
          el('span', { class: 'muted small' }, '(' + x.repo + ')'));
        const list = el('ul', { class: 'small blist' }, b.items.map(row));
        replace(bup, b.items.some((x) => x.state === 'unknown')
          ? el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('Не удалось узнать последние релизы на github.com/amnezia-vpn (GitHub недоступен с роутера?)'), list))
          : b.update
            ? el('div', { class: 'alert info' }, icon('download'), el('div', null, T('Есть новые официальные релизы AmneziaWG.'), list,
              el('div', { class: 'small muted' }, T('Обновление собирает файлы из исходников amnezia-vpn на вашем VPS и проверяет handshake; если туннели не поднимутся — вернутся прежние. По SSH: '), el('code', null, b.cmd)),
              b.vps_ready ? binsUpdateBtn() : el('div', { class: 'small' }, T('Для обновления из панели подключите свой VPS: «Настройки → Свой VPS».'))))
            : el('div', { class: 'alert ok' }, icon('okc'), el('div', null, T('Бинарники AmneziaWG актуальны.'), list)));
      } catch (e) { err(e); }
    }));
    const kv = (rows) => el('dl', { class: 'kv' }, rows.map(([k, v]) => [el('dt', null, k), el('dd', null, v)]));
    const exp = el('button', { class: 'btn' }, icon('download', 'sm'), T('Экспорт настроек'));
    exp.addEventListener('click', async () => {
      try {
        const x = await api('/api/settings/export');
        const a = el('a', { href: URL.createObjectURL(new Blob([JSON.stringify(x, null, 1)], { type: 'application/json' })), download: 'udr-amnezia-settings.json' });
        document.body.appendChild(a); a.click(); a.remove();
      } catch (e) { err(e); }
    });
    const imp = el('button', { class: 'btn' }, icon('upload', 'sm'), T('Импорт настроек'));
    imp.addEventListener('click', () => {
      const m = modal(T('Импорт настроек'), el('div', null, el('p', { class: 'muted small' }, T('Файл udr-amnezia-settings.json с другого роутера или сохранённый ранее: домены, исключения, защита, параметры переключения, названия туннелей. Ключей и паролей в нём нет.')),
        dropZone(async (txt) => {
          let data;
          try { data = JSON.parse(txt); } catch (e) { err(T('это не JSON')); return; }
          const pw = await promptPw(T('Импортировать настройки?'), T('Текущие настройки маршрутизации и переключения будут заменены значениями из файла.'));
          if (pw == null) return;
          try { const x = await api('/api/settings/import', { data, current: pw }); ok(x.msg.split('\n')[0]); m.close(); } catch (e) { err(e); }
        }, 'udr-amnezia-settings.json')), []);
    });
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Версии и обновление'), el('div', null, kv([[T('Набор'), r.version || '?'], [T('Установщик'), r.installer], [T('Панель'), r.panel], ['awg', r.awg], ['amneziawg-go', r.amneziawg_go], ['Python', r.python], [T('Свободно в /data'), r.data_free_mb + T(' МБ')], [T('Канал обновлений'), chSel]]),
          el('div', { class: 'spacer' }), upd, bup, blog, log), { icon: 'info', foot: [chk, bchk] }),
        card(T('Перенос настроек'), el('div', null, el('p', { class: 'muted small' }, T('Настройки без секретов в файл JSON: перенести на другой роутер или сохранить перед экспериментами. Конфиги туннелей переносятся отдельно (Туннели → Настроить → Экспорт) или резервной копией.'))),
          { icon: 'archive', foot: [exp, imp] }))]);
  }
  async function setWeb(body) {
    let r;
    try { r = await api('/api/web'); } catch (e) { err(e); return; }
    const port = el('input', { class: 'input mono', value: r.port, inputmode: 'numeric' });
    const allow = el('input', { class: 'input mono', value: r.allow });
    const hosts = el('input', { class: 'input mono', value: r.hosts, placeholder: 'udr.example.com' });
    const cm = el('select', { class: 'input' }, [['auto', T('Автоматически: сертификат UniFi, если он настоящий, иначе свой')], ['unifi', T('Сертификат UniFi (как у веб-интерфейса роутера)')], ['self', T('Свой самоподписанный')]]
      .map(([v, t]) => el('option', { value: v, selected: r.cert_mode === v }, t)));
    const ci = r.cert || {};
    const certKv = el('dl', { class: 'kv' },
      el('dt', null, T('Используется')), el('dd', null, el('span', { class: 'badge ' + (r.cert_used === 'unifi' || r.cert_used === 'file' ? 'ok' : 'warn') }, { self: T('самоподписанный'), unifi: T('сертификат UniFi'), file: T('файл из web.conf') }[r.cert_used] || T('нет (HTTP)'))),
      el('dt', null, T('Имя')), el('dd', null, ci.subject || '—'),
      el('dt', null, T('Издатель')), el('dd', null, ci.issuer || '—'),
      el('dt', null, T('Действует до')), el('dd', null, ci.expires ? fmtTime(ci.expires, true) + (ci.expires - Date.now() / 1000 < 14 * 86400 ? ' ⚠' : '') : '—'),
      el('dt', null, T('Имена в сертификате')), el('dd', null, (ci.names || []).join(', ') || '—'));
    const found = r.unifi_certs.length ? el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Найден сертификат UniFi')), el('th', null, T('Издатель')), el('th', null, T('До')))),
      el('tbody', null, r.unifi_certs.map((c) => el('tr', null, el('td', null, el('b', null, c.subject || '?'), el('div', { class: 'small muted mono' }, c.path)), el('td', null, c.issuer || '—', c.self_signed ? el('span', { class: 'badge warn' }, T('самоподписанный')) : null), el('td', { class: 'nowrap' }, c.expires ? fmtTime(c.expires, true) : '—')))))
      : el('div', { class: 'small muted' }, T('Сертификатов UniFi не найдено в /data/unifi-core/config.'));
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить и перезапустить панель'));
    save.addEventListener('click', () => busy(save, async () => {
      try {
        const x = await api('/api/web', { port: port.value.trim(), allow: allow.value.trim(), hosts: hosts.value.trim(), cert_mode: cm.value });
        ok(x.msg);
        setTimeout(() => { location.href = x.url; }, 5000);
      } catch (e) { err(e); }
    }));
    add(body, [
      el('div', { class: 'grid g-2e' },
        card(T('Доступ'), el('div', null,
          el('div', { class: 'field' }, el('label', null, T('Порт')), port, el('span', { class: 'hint' }, T('Сейчас панель на ') + r.lan + ':' + r.port + T('. Порты UniFi (443, 8443, 8080…) заняты.'))),
          el('div', { class: 'field' }, el('label', null, T('Разрешённые сети')), allow, el('span', { class: 'hint' }, T('Только частные сети через пробел. Для доступа извне используйте VPN-сервер роутера.'))),
          el('div', { class: 'field' }, el('label', null, T('Имена для входа (кроме IP)')), hosts, el('span', { class: 'hint' }, T('Имена из сертификата добавляются сами.')))), { icon: 'lock' }),
        card(T('Сертификат HTTPS'), el('div', null,
          el('div', { class: 'field' }, el('label', null, T('Источник')), cm, el('span', { class: 'hint' }, T('Сертификат UniFi обновляется роутером; панель перечитывает его сама в течение минуты, перезапуск не нужен.'))),
          r.cert_warn ? el('div', { class: 'alert warn' }, icon('alert'), el('div', null, r.cert_warn)) : null,
          certKv, el('div', { class: 'spacer' }), found), { icon: 'shield' })),
      el('div', { class: 'row end' }, save)]);
  }

