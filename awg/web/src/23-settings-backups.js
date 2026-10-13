  async function setBackups(body) {
    const tb = el('tbody');
    const load = async () => {
      const r = await api('/api/backups');
      replace(tb, r.backups.length ? r.backups.map((b) => el('tr', null,
        el('td', null, el('span', { class: 'mono' }, b.name)),
        el('td', null, fmtTime(b.time, true)),
        el('td', null, fmtBytes(b.size)),
        el('td', null, b.enc ? el('span', { class: 'badge ok' }, T('зашифрована')) : el('span', { class: 'badge warn' }, T('без пароля'))),
        el('td', { class: 'r nowrap' }, el('button', { class: 'btn sm', onclick: () => {
          const pw = el('input', { class: 'input', type: 'password', autocomplete: 'off' });
          const out = el('div', { class: 'res hidden' });
          const go = el('button', { class: 'btn primary' }, T('Проверить'));
          go.addEventListener('click', () => busy(go, async () => { try { const x = await api('/api/backup/verify', { name: b.name, password: pw.value }); out.textContent = x.msg; out.classList.remove('hidden'); (x.ok ? ok : err)(x.ok ? T('Копия читается') : T('Копия не прошла проверку')); } catch (e) { err(e); } }));
          const vm = modal(T('Проверить ') + b.name, el('div', null, el('p', { class: 'muted small' }, T('Копия расшифровывается во временный файл и проверяется целостность архива; на роутере ничего не меняется.')),
            b.enc ? el('div', { class: 'field' }, el('label', null, T('Пароль копии')), pw) : null, out), [el('button', { class: 'btn', onclick: () => vm.close() }, T('Закрыть')), go]);
        } }, icon('okc', 'sm'), T('Проверить')), ' ',
          el('a', { class: 'btn sm', href: '/api/backup/file?name=' + encodeURIComponent(b.name), download: b.name }, icon('download', 'sm'), T('Скачать')), ' ',
          el('button', { class: 'btn sm danger icon', 'aria-label': T('Удалить'), onclick: async () => {
            if (!await confirmBox(T('Удалить копию?'), b.name, T('Удалить'), true)) return;
            try { await api('/api/backup/delete', { name: b.name }); load(); } catch (e) { err(e); }
          } }, icon('trash', 'sm'))))) : el('tr', null, el('td', { class: 'empty', colspan: 5 }, T('Копий пока нет'))));
    };
    const p1 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const p2 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const mk = el('button', { class: 'btn primary' }, icon('archive', 'sm'), T('Создать копию'));
    const res = el('div', { class: 'res hidden' });
    mk.addEventListener('click', () => busy(mk, async () => {
      if (p1.value !== p2.value) { err(T('пароли не совпадают')); return; }
      try { const x = await api('/api/backup/create', { password: p1.value }); res.textContent = x.msg; res.classList.remove('hidden'); (x.ok ? ok : err)(x.ok ? T('Копия создана') : T('Ошибка')); p1.value = p2.value = ''; load(); } catch (e) { err(e); }
    }));
    add(body, [
      card(T('Новая копия'), el('div', null, el('p', { class: 'muted' }, T('В копию входят конфиги туннелей с ключами, awg.env, Telegram и пользователи панели. Она шифруется паролем — храните его отдельно. Восстановление: install.sh → Резервная копия.')),
        el('div', { class: 'form-grid' }, el('div', { class: 'field' }, el('label', null, T('Пароль копии')), p1), el('div', { class: 'field' }, el('label', null, T('Повторите')), p2)), res), { icon: 'archive', foot: mk }),
      await autoBackupCard(load),
      card(T('Копии на роутере'), el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Файл')), el('th', null, T('Создана')), el('th', null, T('Размер')), el('th', null, ''), el('th', null, ''))), tb)), { icon: 'archive', flush: true })]);
    load().catch(err);
  }
  // автокопия вне роутера (#12): по расписанию, шифрованная, на свой VPS (scp ключом роутера) и/или документом в Telegram
  async function autoBackupCard(reloadList) {
    let r;
    try { r = await api('/api/backup/auto'); } catch (e) { err(e); return null; }
    const sched = el('select', { class: 'input' }, el('option', { value: 'no' }, T('выключена')), el('option', { value: 'daily' }, T('ежедневно, ночью')), el('option', { value: 'weekly' }, T('еженедельно, в воскресенье ночью')));
    sched.value = r.auto;
    const keep = el('input', { class: 'input mono', value: r.keep, inputmode: 'numeric' });
    const pass = el('input', { class: 'input', type: 'password', autocomplete: 'new-password', placeholder: r.pass_set ? T('задан — оставьте пустым, чтобы не менять') : T('не короче 8 символов') });
    const pass2 = el('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
    const vps = el('input', { type: 'checkbox', checked: r.vps });
    const host = el('input', { class: 'input mono', value: r.vps_host, placeholder: r.vps_host_default || 'vps.example.com', spellcheck: 'false' });
    const port = el('input', { class: 'input mono', value: r.vps_port, inputmode: 'numeric' });
    const user = el('input', { class: 'input mono', value: r.vps_user, spellcheck: 'false' });
    const dir = el('input', { class: 'input mono', value: r.vps_dir, spellcheck: 'false' });
    const vkeep = el('input', { class: 'input mono', value: r.vps_keep, inputmode: 'numeric' });
    const tg = el('input', { type: 'checkbox', checked: r.tg, disabled: !r.tg_ready && !r.tg });
    const out = el('pre', { class: 'res hidden' });
    const hist = el('tbody');
    const paintHist = (h) => replace(hist, h.length ? h.map((x) => el('tr', null,
      el('td', { class: 'nowrap' }, fmtTime(x.time, true)),
      el('td', null, el('span', { class: 'badge ' + (x.ok ? 'ok' : 'crit') }, x.ok ? T('успешно') : T('ошибка'))),
      el('td', { class: 'small' }, x.msg))) : el('tr', null, el('td', { class: 'empty', colspan: 3 }, T('Автокопия ещё не запускалась'))));
    paintHist(r.history);
    const vpsBox = el('div', { class: 'form-grid' + (r.vps ? '' : ' hidden') },
      el('div', { class: 'field' }, el('label', null, T('Адрес VPS')), host, el('span', { class: 'hint' }, r.vps_host_default ? T('Пусто — ваш VPS из настройки: ') + r.vps_host_default : T('IP или имя сервера'))),
      el('div', { class: 'field' }, el('label', null, T('Порт SSH')), port),
      el('div', { class: 'field' }, el('label', null, T('Пользователь')), user),
      el('div', { class: 'field' }, el('label', null, T('Папка на VPS')), dir),
      el('div', { class: 'field' }, el('label', null, T('Хранить на VPS, копий')), vkeep));
    vps.addEventListener('change', () => vpsBox.classList.toggle('hidden', !vps.checked));
    const sw = (inp, t, h) => el('div', { class: 'setting' }, el('div', { class: 'txt' }, el('b', null, t), el('span', null, h)), el('div', { class: 'ctl auto' }, el('label', { class: 'switch' }, inp, el('span', { class: 'knob' }))));
    const save = el('button', { class: 'btn primary' }, icon('check', 'sm'), T('Сохранить'));
    save.addEventListener('click', () => busy(save, async () => {
      if (pass.value !== pass2.value) { err(T('пароли не совпадают')); return; }
      try {
        const x = await api('/api/backup/auto', { auto: sched.value, keep: keep.value.trim(), pass: pass.value, vps: vps.checked, vps_host: host.value.trim(), vps_port: port.value.trim(),
          vps_user: user.value.trim(), vps_dir: dir.value.trim(), vps_keep: vkeep.value.trim(), tg: tg.checked });
        (x.ok ? ok : err)(x.msg); if (pass.value) r.pass_set = true; pass.value = pass2.value = '';
      } catch (e) { err(e); }
    }));
    const test = el('button', { class: 'btn' }, icon('activity', 'sm'), T('Проверить VPS'));
    test.addEventListener('click', () => busy(test, async () => { try { const x = await api('/api/backup/auto/test', {}); (x.ok ? ok : err)(x.ok ? T('VPS доступен') : T('VPS недоступен')); out.textContent = x.msg; out.classList.remove('hidden'); } catch (e) { err(e); } }));
    const now = el('button', { class: 'btn' }, icon('archive', 'sm'), T('Сделать сейчас'));
    now.addEventListener('click', () => busy(now, async () => {
      try {
        ok((await api('/api/backup/auto/run', {})).msg);
        const before = r.history.length ? r.history[0].time : 0;
        for (let i = 0; i < 45; i++) {
          await new Promise((ok2) => setTimeout(ok2, 2000));
          const x = await api('/api/backup/auto');
          if (x.history.length && x.history[0].time !== before && !x.running) { r.history = x.history; paintHist(x.history); (x.history[0].ok ? ok : err)(x.history[0].ok ? T('Автокопия готова') : T('Автокопия не удалась')); reloadList().catch(err); return; }
        }
      } catch (e) { err(e); }
    }));
    return card(T('Автокопия вне роутера'), el('div', null,
      el('div', { class: 'row wrap' }, el('span', { class: 'badge ' + (r.timer ? 'ok' : '') }, r.timer ? T('по расписанию') : T('расписание выключено')),
        el('span', { class: 'badge ' + (r.pass_set ? 'ok' : 'warn') }, r.pass_set ? T('пароль задан') : T('пароль не задан'))),
      el('p', { class: 'muted small' }, T('Копия шифруется паролем автокопии, после создания проверяется расшифровкой и отправляется на ваш VPS и/или в Telegram администраторам. Пароль хранится на роутере (файл 600) — запишите его отдельно: без него копию не открыть, а при потере роутера он пропадёт вместе с ним.')),
      el('div', { class: 'form-grid' },
        el('div', { class: 'field' }, el('label', null, T('Расписание')), sched, el('span', { class: 'hint' }, T('Около 04:20–05:00; пропущенный запуск выполнится после включения роутера'))),
        el('div', { class: 'field' }, el('label', null, T('Хранить на роутере, копий')), keep),
        el('div', { class: 'field' }, el('label', null, T('Пароль автокопии')), pass),
        el('div', { class: 'field' }, el('label', null, T('Повторите')), pass2)),
      sw(vps, T('На свой VPS'), r.key ? T('По SSH ключом роутера (создаётся установщиком при настройке VPS). Сумма файла сверяется на сервере.') : T('Ключа роутера нет: запустите install.sh → VPS или добавьте ключ вручную.')),
      vpsBox,
      sw(tg, T('В Telegram'), r.tg_ready ? T('Файлом администраторам бота (TG_CHAT); «только просмотр» копии не получают.') : T('Сначала настройте Telegram.')),
      out,
      el('div', { class: 'tbl-wrap' }, el('table', { class: 'tbl' }, el('thead', null, el('tr', null, el('th', null, T('Запуск')), el('th', null, ''), el('th', null, T('Итог')))), hist))),
    { icon: 'archive', foot: [now, test, save] });
  }
