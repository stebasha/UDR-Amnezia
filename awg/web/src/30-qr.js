  // ===================================================================== QR-код (байтовый режим, уровень M, версии 1–10)
  function qrMatrix(text) {
    const data = Array.from(new TextEncoder().encode(text));
    const ECC = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26], BLK = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];
    const rawMods = (v) => { let r = (16 * v + 128) * v + 64; if (v >= 2) { const n = Math.floor(v / 7) + 2; r -= (25 * n - 10) * n - 55; if (v >= 7) r -= 36; } return r; };
    let ver = 1, cap = 0;
    for (; ver <= 10; ver++) { cap = Math.floor(rawMods(ver) / 8) - ECC[ver] * BLK[ver]; if (4 + (ver < 10 ? 8 : 16) + data.length * 8 <= cap * 8) break; }
    if (ver > 10) throw new Error(T('слишком длинно для QR'));
    const bits = [];
    const push = (v, n) => { for (let i = n - 1; i >= 0; i--) bits.push((v >>> i) & 1); };
    push(4, 4); push(data.length, ver < 10 ? 8 : 16); data.forEach((b) => push(b, 8));
    push(0, Math.min(4, cap * 8 - bits.length)); push(0, (8 - bits.length % 8) % 8);
    for (let p = 0xEC; bits.length < cap * 8; p ^= 0xEC ^ 0x11) push(p, 8);
    const cw = [];
    for (let i = 0; i < bits.length; i += 8) { let b = 0; for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j]; cw.push(b); }
    // Рида — Соломона
    const mul = (x, y) => { let z = 0; for (let i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >>> 7) * 0x11D); z ^= ((y >>> i) & 1) * x; } return z & 0xFF; };
    const deg = ECC[ver], div = new Array(deg).fill(0);
    div[deg - 1] = 1;
    for (let i = 0, root = 1; i < deg; i++) { for (let j = 0; j < deg; j++) { div[j] = mul(div[j], root); if (j + 1 < deg) div[j] ^= div[j + 1]; } root = mul(root, 2); }
    const rem = (d) => { const r = new Array(deg).fill(0); for (const b of d) { const f = b ^ r.shift(); r.push(0); div.forEach((c, i) => { r[i] ^= mul(c, f); }); } return r; };
    const nb = BLK[ver], raw = Math.floor(rawMods(ver) / 8), nShort = nb - raw % nb, shortLen = Math.floor(raw / nb);
    const blocks = [];
    for (let i = 0, k = 0; i < nb; i++) {
      const d = cw.slice(k, k + shortLen - deg + (i < nShort ? 0 : 1));
      k += d.length;
      const e = rem(d);
      if (i < nShort) d.push(0);
      blocks.push(d.concat(e));
    }
    const all = [];
    for (let i = 0; i < blocks[0].length; i++) blocks.forEach((b, j) => { if (i !== shortLen - deg || j >= nShort) all.push(b[i]); });
    // матрица
    const N = ver * 4 + 17;
    const M = [], F = [];
    for (let y = 0; y < N; y++) { M.push(new Array(N).fill(false)); F.push(new Array(N).fill(false)); }
    const setF = (x, y, d) => { M[y][x] = d; F[y][x] = true; };
    for (let i = 0; i < N; i++) { setF(6, i, i % 2 === 0); setF(i, 6, i % 2 === 0); }
    const finder = (x, y) => { for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) { const d = Math.max(Math.abs(dx), Math.abs(dy)), xx = x + dx, yy = y + dy; if (xx >= 0 && xx < N && yy >= 0 && yy < N) setF(xx, yy, d !== 2 && d !== 4); } };
    finder(3, 3); finder(N - 4, 3); finder(3, N - 4);
    if (ver > 1) {
      const na = Math.floor(ver / 7) + 2, step = Math.ceil((ver * 4 + 4) / (na * 2 - 2)) * 2;
      const pos = [6];
      for (let p = N - 7; pos.length < na; p -= step) pos.splice(1, 0, p);
      for (let i = 0; i < na; i++) for (let j = 0; j < na; j++) {
        if ((i === 0 && j === 0) || (i === 0 && j === na - 1) || (i === na - 1 && j === 0)) continue;
        for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) setF(pos[i] + dx, pos[j] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
      }
    }
    const fmt = (mask) => {
      const d = (0 << 3) | mask;
      let r = d;
      for (let i = 0; i < 10; i++) r = (r << 1) ^ ((r >>> 9) * 0x537);
      const b = ((d << 10) | r) ^ 0x5412, g = (i) => ((b >>> i) & 1) !== 0;
      for (let i = 0; i <= 5; i++) setF(8, i, g(i));
      setF(8, 7, g(6)); setF(8, 8, g(7)); setF(7, 8, g(8));
      for (let i = 9; i < 15; i++) setF(14 - i, 8, g(i));
      for (let i = 0; i < 8; i++) setF(N - 1 - i, 8, g(i));
      for (let i = 8; i < 15; i++) setF(8, N - 15 + i, g(i));
      setF(8, N - 8, true);
    };
    fmt(0);
    if (ver >= 7) {
      let r = ver;
      for (let i = 0; i < 12; i++) r = (r << 1) ^ ((r >>> 11) * 0x1F25);
      const b = (ver << 12) | r;
      for (let i = 0; i < 18; i++) { const bit = ((b >>> i) & 1) !== 0, a = N - 11 + i % 3, c = Math.floor(i / 3); setF(a, c, bit); setF(c, a, bit); }
    }
    let i = 0;
    for (let right = N - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (let v = 0; v < N; v++) for (let j = 0; j < 2; j++) {
        const x = right - j, up = ((right + 1) & 2) === 0, y = up ? N - 1 - v : v;
        if (!F[y][x] && i < all.length * 8) { M[y][x] = ((all[i >>> 3] >>> (7 - (i & 7))) & 1) !== 0; i++; }
      }
    }
    const MASKS = [(x, y) => (x + y) % 2 === 0, (x, y) => y % 2 === 0, (x) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
      (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => x * y % 2 + x * y % 3 === 0,
      (x, y) => (x * y % 2 + x * y % 3) % 2 === 0, (x, y) => ((x + y) % 2 + x * y % 3) % 2 === 0];
    const apply = (m) => { for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (!F[y][x] && MASKS[m](x, y)) M[y][x] = !M[y][x]; };
    const penalty = () => {
      let p = 0, dark = 0;
      for (let a = 0; a < N; a++) {
        for (const line of [(k) => M[a][k], (k) => M[k][a]]) {
          let run = 1;
          for (let k = 1; k < N; k++) { if (line(k) === line(k - 1)) { run++; if (run === 5) p += 3; else if (run > 5) p++; } else run = 1; }
          for (let k = 0; k + 10 < N; k++) {
            const s = []; for (let q = 0; q < 11; q++) s.push(line(k + q) ? 1 : 0);
            const t = s.join('');
            if (t === '10111010000' || t === '00001011101') p += 40;
          }
        }
      }
      for (let y = 0; y < N - 1; y++) for (let x = 0; x < N - 1; x++) { const c = M[y][x]; if (c === M[y][x + 1] && c === M[y + 1][x] && c === M[y + 1][x + 1]) p += 3; }
      for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (M[y][x]) dark++;
      p += Math.floor(Math.abs(dark * 20 - N * N * 10) / (N * N)) * 10;
      return p;
    };
    let best = 0, bestP = Infinity;
    for (let m = 0; m < 8; m++) { apply(m); fmt(m); const p = penalty(); if (p < bestP) { bestP = p; best = m; } apply(m); }
    apply(best); fmt(best);
    return M;
  }
  function qrSvg(text) {
    const M = qrMatrix(text), N = M.length, q = 4;
    let d = '';
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (M[y][x]) d += 'M' + (x + q) + ' ' + (y + q) + 'h1v1h-1z';
    return sv('svg', { class: 'qr', viewBox: '0 0 ' + (N + 2 * q) + ' ' + (N + 2 * q), 'shape-rendering': 'crispEdges', role: 'img', 'aria-label': T('QR-код для приложения') },
      sv('rect', { width: N + 2 * q, height: N + 2 * q, fill: '#fff' }), sv('path', { d, fill: '#000' }));
  }
  window.__awgQR = qrMatrix;  // для автотестов

