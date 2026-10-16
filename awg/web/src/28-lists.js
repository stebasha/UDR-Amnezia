  // списки и GeoIP (#38): состояние наборов и кнопка «Обновить списки» над формой настроек
  function listsStatus() {
    const box = el('div', { class: 'stack' });
    let polling = false;
    const load = async () => {
      let r;
      try { r = await api('/api/lists'); } catch (e) { replace(box, el('div', { class: 'muted small' }, String(e.message || e))); return; }
      const st = r.status || {}, sets = st.sets || {};
      if (st.mode === 'off' || !st.mode) { replace(box, el('p', { class: 'muted small' }, T('Сейчас выключено: устройства под PBR идут через туннель целиком. Выберите режим и нажмите «Применить» — списки скачаются сами.'))); return; }
      const k = st.mode === 'geoip' ? 'geo' : 'blocked', x = sets[k] || {};
      const what = st.mode === 'geoip' ? T('Адресов стран ') + (st.countries || '').toUpperCase().trim() + ': ' : T('Сетей в списке заблокированного: ');
      const badge = !r.guard ? el('span', { class: 'badge crit' }, T('служба awg-guard не запущена'))
        : x.set > 0 ? el('span', { class: 'badge ok' }, T('работает'))
          : el('span', { class: 'badge warn' }, T('набор пуст — пока всё идёт через туннель'));
      const go = el('button', { class: 'btn sm', disabled: r.running }, icon('refresh', 'sm'), r.running ? T('Обновляется…') : T('Обновить списки'));
      go.addEventListener('click', () => busy(go, async () => {
        try { ok(TM((await api('/api/lists/update', {})).msg)); follow(); } catch (e) { err(e); }
      }));
      const log = el('div', { class: 'out' + (r.log && r.running ? '' : ' hidden') });
      if (r.log) paint(log, r.log);
      const showLog = el('button', { class: 'btn sm ghost' + (r.log ? '' : ' hidden') }, T('Журнал'));
      showLog.addEventListener('click', () => log.classList.toggle('hidden'));
      // режим только сужает то, что UniFi уже ведёт в туннель: без маршрута «весь интернет» он ни на что не влияет
      const nofull = st.full === 0 ? el('div', { class: 'alert warn' }, icon('alert'), el('div', null, T('В UniFi нет маршрута PBR на весь трафик в туннель: сейчас через туннель идут только домены и адреса из маршрутов UniFi, и этот режим ни на что не влияет (сайты вроде ifconfig.me покажут ваш IP). Создайте в UniFi маршрут по политике: устройства (или сеть) → VPN-клиент, назначение — весь интернет, Kill Switch UniFi не включать (его заменяет сторож, а DNS он ломает).'))) : null;
      replace(box, nofull,
        el('div', { class: 'row' }, badge, el('span', { class: 'small' }, what, el('b', null, String(x.set || 0))),
          el('span', { class: 'small muted' }, T('обновлено: ') + (x.age >= 0 ? fmtAge(x.age) : T('никогда'))),
          x.stale && x.age >= 0 ? el('span', { class: 'badge warn' }, T('собрано для прежних настроек')) : null, go, showLog),
        log);
      if (r.running && !polling) follow();
    };
    async function follow() {
      if (polling) return;
      polling = true;
      for (let i = 0; i < 100; i++) {
        await new Promise((ok2) => setTimeout(ok2, 3000));
        let x;
        try { x = await api('/api/lists'); } catch (e) { continue; }
        const lg = box.querySelector('.out');
        if (lg) { lg.classList.remove('hidden'); paint(lg, x.log); }
        if (!x.running) break;
      }
      polling = false;
      load();
    }
    load();
    return box;
  }
