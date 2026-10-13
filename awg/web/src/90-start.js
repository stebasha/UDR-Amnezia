  // ===================================================================== запуск
  function start() {
    shell();
    if (!location.hash || location.hash === '#' || location.hash === '#/') location.hash = '#/overview';
    route();
  }
  (async function boot() {
    try {
      const r = await fetch('/api/session', { credentials: 'same-origin', cache: 'no-store' });
      const j = await r.json();
      if (r.ok) { S.csrf = j.csrf; S.user = j.user; S.version = j.version; checkVersion(j.version); start(); } else showLogin(j.setup);
    } catch (e) {
      replace($('#app'), el('div', { class: 'login-wrap' }, el('div', { class: 'login' }, el('div', { class: 'alert crit' }, icon('alert'), el('div', null, T('Панель не отвечает: ') + e.message)))));
    }
  }());
}());
