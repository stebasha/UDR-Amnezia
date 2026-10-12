#!/usr/bin/env python3
"""Синхронизирует скрипты, встроенные в гайд index.html, с файлами репозитория (awg/, server/).

Блок гайда вида
    cat > /data/awg/failover.sh <<'EOF'      (или /root/awg-server-setup.sh)
    ...содержимое...
    EOF
получает текущее содержимое awg/failover.sh (server/... для /root/...). Обновляется и подпись
«Показать целиком · N строк». Запуск из корня репозитория:
    python3 tools/sync-guide.py           обновить index.html
    python3 tools/sync-guide.py --check   только проверить (код 1, если гайд отстал от скриптов) — для CI
"""
import html, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUIDE = os.path.join(ROOT, 'index.html')
HEAD = re.compile(r'(<pre><code>cat &gt; (/data/awg|/root)/([A-Za-z0-9._-]+) &lt;&lt;\'EOF\'\n)(.*?)(\nEOF\n)(.*?</code></pre>)(<button class="more"[^>]*data-label="Показать целиком · )?(\d+)?', re.S)


def render(text):
    out = []
    for line in text.rstrip('\n').split('\n'):
        esc = html.escape(line, quote=False)
        out.append('<span class="c">%s</span>' % esc if line.lstrip().startswith('#') else esc)
    return '\n'.join(out)


def source(where, name):
    for d in (['awg', 'server'] if where == '/data/awg' else ['server', 'awg']):
        p = os.path.join(ROOT, d, name)
        if os.path.isfile(p):
            return p
    return None


def sync(s):
    missing = []

    def repl(m):
        where, name = m.group(2), m.group(3)
        p = source(where, name)
        if not p:
            missing.append(name)
            return m.group(0)
        text = open(p, encoding='utf-8').read()
        assert '\nEOF\n' not in '\n' + text + '\n', name + ': строка EOF внутри файла'
        body = render(text)
        res = m.group(1) + body + m.group(5) + m.group(6)
        if m.group(7):
            tail_lines = m.group(6).count('\n')
            total = body.count("\n") + tail_lines + 4      # строки: cat, тело, EOF, хвост
            res += m.group(7) + str(total)
        return res

    s2 = HEAD.sub(repl, s)
    # подпись внутри кнопки повторяет data-label
    s2 = re.sub(r'(data-label="Показать целиком · (\d+) строк">)Показать целиком · \d+ строк', r'\1Показать целиком · \2 строк', s2)
    return s2, missing


def main():
    s = open(GUIDE, encoding='utf-8').read()
    s2, missing = sync(s)
    if missing:
        print('нет файлов в репозитории для блоков:', ', '.join(sorted(set(missing))))
    if '--check' in sys.argv:
        if s2 != s:
            print('index.html отстал от скриптов: выполните python3 tools/sync-guide.py')
            sys.exit(1)
        print('гайд совпадает со скриптами')
        return
    if s2 != s:
        open(GUIDE, 'w', encoding='utf-8').write(s2)
        print('index.html обновлён')
    else:
        print('изменений нет')


if __name__ == '__main__':
    main()
