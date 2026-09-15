#!/usr/bin/env python3
"""Build Medora's food-supplement register data file.

Downloads the Italian Ministry of Health register of notified food supplements
(PDF, updated monthly) and converts it to a gzipped CSV with the columns
`code,product,company`, which the app downloads and caches for offline lookup
of the "COD MINSAN" / notification code printed on supplement labels.

Usage:
  tools/build_supplements_data.py [--pdf PATH] [--out integratori.csv.gz]
                                  [--publish [--repo OWNER/NAME]]
  tools/build_supplements_data.py --self-test   # offline checks, no download

Requires Python 3 (stdlib only) and `pdftotext` (poppler-utils); --publish
also needs an authenticated `gh`. Without --pdf the script fetches
INTEGRATORI_NOTIFICATI_ORD_PROD_<n>.pdf, discovering the current file name
from the register page. The Ministry site blocks non-browser and non-Italian
traffic (GitHub-hosted runners get an HTML challenge page), so run it from a
machine in Italy.

Next to the CSV it writes `integratori.meta.json` (rows, sourceUpdated from the
PDF's "aggiornato al dd/mm/yyyy", builtAt, source, columns). With --publish
both files are uploaded to the pre-release `data-integratori` (created if
missing; a pre-release so `releases/latest` keeps returning the app release).
"""
import argparse
import csv
import gzip
import html
import io
import json
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

REGISTER_PAGE = (
    'https://www.salute.gov.it/new/it/tema/alimenti-fini-medici-speciali-ed-integratori/'
    'registro-degli-integratori-alimentari'
)
BASE = 'https://www.salute.gov.it'
RELEASE_TAG = 'data-integratori'
DEFAULT_REPO = '13/medora'
BLOCKED_HINT = ('the download is not a PDF: the Ministry site blocks non-browser or '
                'non-Italian traffic; run this from a machine in Italy or pass --pdf')
UA = ('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0 Safari/537.36')

PAGE_RE = re.compile(r'<page width="([\d.]+)" height="([\d.]+)">(.*?)</page>', re.S)
WORD_RE = re.compile(
    r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>')


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'it-IT,it;q=0.9'})
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        raise SystemExit(f'download failed: HTTP {e.code} {e.reason} for {url}; {BLOCKED_HINT}')
    except urllib.error.URLError as e:
        raise SystemExit(f'download failed: {e.reason} for {url}')


def _pick_latest(names):
    """The register PDF path with the highest numeric suffix.

    >>> _pick_latest(['/f/INTEGRATORI_NOTIFICATI_ORD_PROD_9.pdf',
    ...               '/f/INTEGRATORI_NOTIFICATI_ORD_PROD_10.pdf'])
    '/f/INTEGRATORI_NOTIFICATI_ORD_PROD_10.pdf'
    >>> _pick_latest(['/f/INTEGRATORI_NOTIFICATI_ORD_PROD_123.pdf'])
    '/f/INTEGRATORI_NOTIFICATI_ORD_PROD_123.pdf'
    """
    return max(names, key=lambda n: int(re.search(r'_(\d+)\.pdf$', n)[1]))


def self_test() -> int:
    """Runs the doctests of this module (no network, no pdftotext)."""
    import doctest
    failed, attempted = doctest.testmod(sys.modules[__name__])
    print(f'self-test: {attempted - failed}/{attempted} checks passed', file=sys.stderr)
    return 1 if failed else 0


def discover_pdf_url() -> str:
    page = fetch(REGISTER_PAGE).decode('utf-8', 'ignore').replace('\\u002F', '/')
    names = set(re.findall(r'/new/sites/default/files/INTEGRATORI_NOTIFICATI_ORD_PROD_\d+\.pdf', page))
    if not names:
        raise SystemExit(f'register PDF link not found on the register page; {BLOCKED_HINT}')
    return BASE + _pick_latest(names)


def source_updated(pdf: Path):
    """ISO date from the first page's "aggiornato al dd/mm/yyyy", else None."""
    text = subprocess.run(['pdftotext', '-f', '1', '-l', '1', str(pdf), '-'],
                          check=True, capture_output=True, text=True).stdout
    m = re.search(r'aggiornato al\s+(\d{1,2})/(\d{1,2})/(\d{4})', text, re.I)
    if not m:
        return None
    day, month, year = (int(g) for g in m.groups())
    return f'{year:04d}-{month:02d}-{day:02d}'


def write_meta(path: Path, rows: int, updated, source: str) -> None:
    meta = {
        'rows': rows,
        'sourceUpdated': updated,
        'builtAt': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'source': source,
        'columns': ['code', 'product', 'company'],
    }
    path.write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8')


def publish(files, repo: str) -> None:
    """Upload [files] to the pre-release RELEASE_TAG, creating it if missing."""
    exists = subprocess.run(['gh', 'release', 'view', RELEASE_TAG, '-R', repo],
                            capture_output=True).returncode == 0
    if not exists:
        subprocess.run(['gh', 'release', 'create', RELEASE_TAG, '--prerelease',
                        '--title', 'Food supplement register data',
                        '--notes', 'Register of notified food supplements (Italian Ministry '
                                   'of Health) as integratori.csv.gz for the Medora app. '
                                   'Refreshed monthly with tools/build_supplements_data.py '
                                   '--publish.',
                        '-R', repo], check=True)
    subprocess.run(['gh', 'release', 'upload', RELEASE_TAG, *map(str, files),
                    '--clobber', '-R', repo], check=True)
    print(f'published {", ".join(map(str, files))} to {repo} {RELEASE_TAG}', file=sys.stderr)


def split_by_gap(words, min_gap=7.0):
    """words: [(x0, x1, text)] sorted by x; split at the widest gap >= min_gap."""
    if len(words) < 2:
        return ' '.join(t for _, _, t in words), ''
    gap, i = max((words[k + 1][0] - words[k][1], k) for k in range(len(words) - 1))
    if gap < min_gap:
        return ' '.join(t for _, _, t in words), ''
    return ' '.join(t for _, _, t in words[:i + 1]), ' '.join(t for _, _, t in words[i + 1:])


def parse_bbox(doc: str):
    """Rows (code, product, company) from `pdftotext -bbox-layout` output."""
    rows, cur = [], None
    for pm in PAGE_RE.finditer(doc):
        words = [(float(a), float(b), float(c), float(d), html.unescape(t))
                 for a, b, c, d, t in WORD_RE.findall(pm.group(3))]
        header = {w[4]: w[0] for w in words if w[4] in ('IMPRESA', 'CODICE')}
        if len(header) < 2:
            continue
        header_y = min(w[1] for w in words if w[4] == 'IMPRESA')
        company_x, code_x = header['IMPRESA'] - 2, header['CODICE'] - 6
        page_h = float(pm.group(2))
        lines = defaultdict(list)
        for x0, y0, x1, _, t in words:
            if y0 <= header_y + 1 or y0 > page_h - 40:  # title/header, footer
                continue
            lines[round(y0 / 2.5)].append((x0, x1, t))
        for key in sorted(lines):
            ws = sorted(lines[key])
            left = [w for w in ws if w[0] < code_x]
            code = ' '.join(t for x0, _, t in ws if x0 >= code_x)
            product = ' '.join(t for x0, _, t in left if x0 < company_x)
            company = ' '.join(t for x0, _, t in left if x0 >= company_x)
            if re.fullmatch(r'\d{2,7}', code):
                if not company:
                    product2, company2 = split_by_gap(left)
                    if company2:
                        product, company = product2, company2
                if cur:
                    rows.append(cur)
                cur = {'code': code, 'product': product, 'company': company}
            elif cur is not None and not code:
                if product:
                    cur['product'] = (cur['product'] + ' ' + product).strip()
                if company:
                    cur['company'] = (cur['company'] + ' ' + company).strip()
    if cur:
        rows.append(cur)
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--pdf', help='local register PDF (skips download)')
    ap.add_argument('--out', default='integratori.csv.gz')
    ap.add_argument('--meta', help='meta JSON path (default: integratori.meta.json next to --out)')
    ap.add_argument('--min-rows', type=int, default=50000,
                    help='fail if fewer rows are parsed (guards against layout changes)')
    ap.add_argument('--publish', action='store_true',
                    help=f'upload the CSV and meta JSON to the {RELEASE_TAG} pre-release with gh')
    ap.add_argument('--repo', default=DEFAULT_REPO, help=f'GitHub repository (default {DEFAULT_REPO})')
    ap.add_argument('--self-test', action='store_true', help='run the offline self-checks and exit')
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    out = Path(args.out)
    meta_path = Path(args.meta) if args.meta else out.with_name('integratori.meta.json')
    with tempfile.TemporaryDirectory() as tmp:
        pdf = Path(args.pdf) if args.pdf else Path(tmp) / 'register.pdf'
        # The meta file is published: never record a local absolute path.
        source = pdf.name if args.pdf else discover_pdf_url()
        if not args.pdf:
            print('downloading', source, file=sys.stderr)
            pdf.write_bytes(fetch(source))
        with pdf.open('rb') as f:
            if f.read(5) != b'%PDF-':
                raise SystemExit(BLOCKED_HINT)
        updated = source_updated(pdf)
        if updated is None:
            print('warning: "aggiornato al" date not found on page 1', file=sys.stderr)
        bbox = Path(tmp) / 'register.html'
        subprocess.run(['pdftotext', '-bbox-layout', str(pdf), str(bbox)], check=True)
        rows = parse_bbox(bbox.read_text(encoding='utf-8', errors='replace'))

    if len(rows) < args.min_rows:
        raise SystemExit(f'only {len(rows)} rows parsed; refusing to publish')
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(['code', 'product', 'company'])
    for r in rows:
        writer.writerow([r['code'], r['product'], r['company']])
    with gzip.open(out, 'wt', encoding='utf-8', newline='') as f:
        f.write(buf.getvalue())
    write_meta(meta_path, len(rows), updated, source)
    print(f'{len(rows)} rows -> {out}, {meta_path} (sourceUpdated {updated})', file=sys.stderr)
    if args.publish:
        publish([out, meta_path], args.repo)
    return 0


if __name__ == '__main__':
    sys.exit(main())
