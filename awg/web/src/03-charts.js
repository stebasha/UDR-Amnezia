  // ===================================================================== графики
  function cssVar(n) { return getComputedStyle(document.documentElement).getPropertyValue(n).trim(); }
  function drawChart(wrap, series, opts) {
    opts = opts || {};
    let cv = wrap.querySelector('canvas');
    if (!cv) { cv = el('canvas'); wrap.appendChild(cv); }
    let tip = wrap.querySelector('.chart-tip');
    const dpr = window.devicePixelRatio || 1;
    const W = wrap.clientWidth, H = wrap.clientHeight;
    if (!W || !H) return;
    cv.width = W * dpr; cv.height = H * dpr;
    const c = cv.getContext('2d');
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, W, H);
    const L = 64, R = 10, TP = 10, B = 24;
    let t0 = Infinity, t1 = -Infinity, ymax = 0;
    for (const s of series) for (const p of s.points) { t0 = Math.min(t0, p[0]); t1 = Math.max(t1, p[0]); ymax = Math.max(ymax, p[1]); }
    const muted = cssVar('--muted'), line = cssVar('--line2');
    c.font = '11px ' + cssVar('--font');
    if (!isFinite(t0) || t1 === t0) {
      c.fillStyle = muted; c.textAlign = 'center';
      c.fillText(opts.empty || T('Данные появятся через несколько секунд'), W / 2, H / 2);
      cv.onmousemove = null;
      return;
    }
    // «красивый» максимум оси Y
    const nice = (v) => { if (v <= 0) return 1000; const e = Math.pow(10, Math.floor(Math.log10(v))); const f = v / e; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * e; };
    ymax = opts.max ? Math.max(opts.max, ymax) : nice(ymax * 1.08);
    const F = opts.fmt || fmtBits;
    const X = (t) => L + (t - t0) / (t1 - t0) * (W - L - R);
    const Y = (v) => TP + (1 - v / ymax) * (H - TP - B);
    c.strokeStyle = line; c.lineWidth = 1; c.fillStyle = muted; c.textAlign = 'right'; c.textBaseline = 'middle';
    for (let i = 0; i <= 4; i++) {
      const v = ymax * i / 4, y = Math.round(Y(v)) + 0.5;
      c.beginPath(); c.moveTo(L, y); c.lineTo(W - R, y); c.stroke();
      c.fillText(opts.fmt ? F(v) : fmtBits(v).replace(T(' бит/с'), T(' б/с')).replace(T('бит/с'), T('б/с')), L - 8, y);
    }
    c.textAlign = 'center'; c.textBaseline = 'top';
    const nx = Math.max(2, Math.min(6, Math.floor((W - L) / 90)));
    for (let i = 0; i <= nx; i++) {
      const t = t0 + (t1 - t0) * i / nx;
      const d = new Date(t * 1000);
      // больше двух суток — подписи датами (7 и 30 дней), иначе временем
      c.fillText(t1 - t0 > 2 * 86400 ? pad2(d.getDate()) + '.' + pad2(d.getMonth() + 1) : pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + (t1 - t0 < 1200 ? ':' + pad2(d.getSeconds()) : ''), Math.min(Math.max(X(t), L + 20), W - R - 20), H - B + 7);
    }
    for (const s of series) {
      if (!s.points.length) continue;
      const col = cssVar(s.color) || s.color;
      if (s.fill) {
        c.beginPath(); c.moveTo(X(s.points[0][0]), Y(0));
        for (const p of s.points) c.lineTo(X(p[0]), Y(p[1]));
        c.lineTo(X(s.points[s.points.length - 1][0]), Y(0)); c.closePath();
        c.globalAlpha = 0.12; c.fillStyle = col; c.fill(); c.globalAlpha = 1;
      }
      c.beginPath();
      s.points.forEach((p, i) => (i ? c.lineTo(X(p[0]), Y(p[1])) : c.moveTo(X(p[0]), Y(p[1]))));
      c.strokeStyle = col; c.lineWidth = 1.8; c.setLineDash(s.dash ? [5, 4] : []); c.stroke(); c.setLineDash([]);
    }
    cv.onmousemove = (e) => {
      const r = cv.getBoundingClientRect(), x = e.clientX - r.left;
      if (x < L) { if (tip) tip.remove(); tip = null; return; }
      const t = t0 + (x - L) / (W - L - R) * (t1 - t0);
      const rows = [];
      for (const s of series) {
        let best = null;
        for (const p of s.points) if (!best || Math.abs(p[0] - t) < Math.abs(best[0] - t)) best = p;
        if (best) rows.push([s, best]);
      }
      if (!rows.length) return;
      if (!tip) { tip = el('div', { class: 'chart-tip' }); wrap.appendChild(tip); }
      replace(tip, el('div', { class: 'muted' }, fmtTime(rows[0][1][0], true)),
        rows.map(([s, p]) => el('div', null, s.name + ': ', el('b', null, F(p[1])))));
      tip.style.left = Math.min(x + 12, W - tip.offsetWidth - 4) + 'px';
      tip.style.top = '8px';
    };
    cv.onmouseleave = () => { if (tip) tip.remove(); tip = null; };
  }
  function sparkline(points) {
    const W = 300, H = 54;
    const s = sv('svg', { viewBox: '0 0 ' + W + ' ' + H, preserveAspectRatio: 'none', 'aria-hidden': 'true' });
    if (!points || points.length < 2) {
      s.appendChild(sv('line', { x1: 0, y1: H - 1, x2: W, y2: H - 1, class: 'ln rx' }));
      return s;
    }
    const pts = points.slice(-90);
    let m = 1;
    for (const p of pts) m = Math.max(m, p[1], p[2]);
    const X = (i) => i / (pts.length - 1) * W, Y = (v) => H - 2 - v / m * (H - 6);
    const path = (k) => pts.map((p, i) => (i ? 'L' : 'M') + X(i).toFixed(1) + ' ' + Y(p[k]).toFixed(1)).join(' ');
    s.appendChild(sv('path', { d: path(1) + ' L' + W + ' ' + H + ' L0 ' + H + ' Z', class: 'ar rx' }));
    s.appendChild(sv('path', { d: path(1), class: 'ln rx' }));
    s.appendChild(sv('path', { d: path(2), class: 'ln tx' }));
    return s;
  }
  function lastRate(t) {
    const q = S.live[t];
    return q && q.length ? q[q.length - 1] : null;
  }

  // ===================================================================== топология
  function topology(ov) {
    const tl = ov.tunnels;
    const n = Math.max(tl.length, 1);
    const rowH = 74, H = Math.max(250, n * rowH + 70);
    const W = 680;
    const s = sv('svg', { class: 'topo', viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': T('Схема подключения') });
    const cy = H / 2 - 12;
    const node = (x, y, w, h, ic, l1, l2, cls, st) => {
      const g = sv('g', { class: cls || '' });
      g.appendChild(sv('rect', { x: x - w / 2, y: y - h / 2, width: w, height: h, rx: 10, class: 'node' + (cls === 'router' ? ' router' : '') }));
      const ig = sv('g', { transform: 'translate(' + (x - w / 2 + 12) + ',' + (y - 11) + ') scale(0.92)', class: 'ic' + (cls === 'router' ? ' acc' : '') });
      for (const d of IC[ic].split('|')) ig.appendChild(sv('path', { d, class: 'ic' + (cls === 'router' ? ' acc' : '') }));
      g.appendChild(ig);
      g.appendChild(sv('text', { x: x - w / 2 + 44, y: y - 3, class: 'b' }, l1));
      if (l2) g.appendChild(sv('text', { x: x - w / 2 + 44, y: y + 13, class: 'm' }, l2));
      if (st) g.appendChild(sv('circle', { cx: x + w / 2 - 10, cy: y - h / 2 + 10, r: 4, class: 'sdot ' + st }));
      return g;
    };
    const link = (x1, y1, x2, y2, cls) => {
      const mx = (x1 + x2) / 2;
      return sv('path', { d: 'M' + x1 + ' ' + y1 + ' C' + mx + ' ' + y1 + ' ' + mx + ' ' + y2 + ' ' + x2 + ' ' + y2, class: 'link ' + cls });
    };
    const xL = 74, xR = 246, xT = 446, xI = 614;
    const links = sv('g'), nodes = sv('g');
    // клиенты → роутер
    links.appendChild(link(xL + 67, cy, xR - 70, cy, 'ok'));
    nodes.appendChild(node(xL, cy, 134, 56, 'laptop', T('Клиенты LAN'), 'PBR ' + (ov.pbr.rail || '—'), '', 'ok'));
    nodes.appendChild(node(xR, cy, 140, 62, 'router', ov.host.length > 13 ? ov.host.slice(0, 12) + '…' : ov.host,
      ov.pbr.killswitch ? T('kill switch: есть') : T('kill switch: НЕТ'), 'router', ov.level === 'crit' ? 'crit' : ov.level === 'warn' ? 'warn' : 'ok'));
    // туннели
    const top = cy - (n - 1) * rowH / 2;
    tl.forEach((t, i) => {
      const y = top + i * rowH;
      const st = t.status === 'active' ? 'ok' : t.status === 'standby' ? 'ok' : t.status === 'nohs' ? 'warn' : 'crit';
      links.appendChild(link(xR + 70, cy, xT - 72, y, t.active ? 'act' : t.status === 'standby' ? 'idle' : st));
      links.appendChild(link(xT + 72, y, xI - 58, cy, t.active ? 'act' : 'idle'));
      const nm = t.label || t.name;
      nodes.appendChild(node(xT, y, 144, 54, 'shield', nm.length > 13 ? nm.slice(0, 12) + '…' : nm,
        (t.active ? T('активен') : STATUS[t.status][1].toLowerCase()) + (t.handshake >= 0 ? ' · ' + (t.handshake < 90 ? t.handshake + T(' с') : Math.round(t.handshake / 60) + T(' мин')) : ''),
        '', t.active ? 'ok' : st === 'ok' ? 'idle' : st));
    });
    nodes.appendChild(node(xI, cy, 116, 56, 'globe', T('Интернет'), ov.wan.if || 'WAN', '', ov.active ? 'ok' : 'crit'));
    // прямой WAN (без PBR)
    const yb = H - 22;
    links.appendChild(sv('path', { d: 'M' + xR + ' ' + (cy + 31) + ' L' + xR + ' ' + yb + ' L' + xI + ' ' + yb + ' L' + xI + ' ' + (cy + 28), class: 'link idle' }));
    nodes.appendChild(sv('text', { x: (xR + xI) / 2, y: yb - 6, class: 'm', 'text-anchor': 'middle' }, T('напрямую через ') + (ov.wan.if || 'WAN') + T(' — устройства вне PBR')));
    s.appendChild(links); s.appendChild(nodes);
    return s;
  }

