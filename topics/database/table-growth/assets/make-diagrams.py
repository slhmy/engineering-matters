#!/usr/bin/env python3
"""Generate the schema diagrams used by topics/database/table-growth/README.md.

The diagrams are plain SVG so they stay readable, diffable and easy to edit.
Run from this directory:

    python3 make-diagrams.py

Every diagram reflects the tables the benchmark SQL actually creates, so when a
column, index or size changes in benchmark/sql/*.sql, update the matching
definition below and re-run this script. Each diagram adapts to light and dark
backgrounds through media queries.
"""

from pathlib import Path

WIDE = 940
NARROW = 840
PAD = 24

LIGHT = dict(
    bg="#ffffff", fg="#1f2328", muted="#59636e", faint="#818b98",
    border="#d1d9e0", panel="#f6f8fa", panel_border="#d1d9e0",
    idx="#0969da", idx_bg="#ddf4ff", pk="#9a6700", pk_bg="#fff8c5",
    toast="#1a7f37", toast_bg="#dafbe1", accent="#8250df", warn="#cf222e",
)

DARK = dict(
    bg="#0d1117", fg="#e6edf3", muted="#9198a1", faint="#6e7681",
    border="#3d444d", panel="#151b23", panel_border="#3d444d",
    idx="#4493f8", idx_bg="#12243d", pk="#d29922", pk_bg="#33280d",
    toast="#3fb950", toast_bg="#0f2a18", accent="#a371f7", warn="#f85149",
)

MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
MONO_STACK = ("ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, "
              "Liberation Mono, monospace")
SANS = "-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif"

# the table card is laid out in lanes: 12px padding, a name lane, then a
# right-aligned type lane with an optional role badge in front of it
ROW_H = 24


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def role_style(role):
    return {
        "pk": ("var(--pk-bg)", "var(--pk)", "PRIMARY KEY"),
        "idx": ("var(--idx-bg)", "var(--idx)", "INDEX"),
        "join": ("var(--idx-bg)", "var(--idx)", "JOIN KEY"),
        "toast": ("var(--toast-bg)", "var(--toast)", "STORAGE"),
        "plain": ("none", "var(--faint)", ""),
    }[role]


class Canvas:
    def __init__(self, width):
        self.width = width
        self.parts = []

    def rect(self, x, y, w, h, r=8, fill="none", stroke="var(--border)", sw=1,
             dash=None, op=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        o = f' opacity="{op}"' if op is not None else ""
        self.parts.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" '
            f'stroke="{stroke}" stroke-width="{sw}"{d}{o}/>')

    def bar(self, x, y, w, h, fill, r=4, op=None):
        o = f' opacity="{op}"' if op is not None else ""
        self.parts.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" '
            f'stroke="none"{o}/>')

    def line(self, x1, y1, x2, y2, stroke="var(--border)", sw=1, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.parts.append(
            f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" '
            f'stroke-width="{sw}" fill="none"{d}/>')

    def text(self, x, y, s, size=12.5, fill="var(--fg)", anchor="start",
             family=MONO, weight="400"):
        self.parts.append(
            f'<text x="{x}" y="{y}" fill="{fill}" font-family="{family}" '
            f'font-size="{size}" font-weight="{weight}" text-anchor="{anchor}">'
            f'{esc(s)}</text>')

    def svg(self, h, title):
        def vars_for(p):
            names = ["bg", "fg", "muted", "faint", "border", "panel",
                     "panel_border", "idx", "idx_bg", "pk", "pk_bg", "toast",
                     "toast_bg", "accent", "warn"]
            return " ".join(f"--{n.replace('_', '-')}: {p[n]};" for n in names)

        head = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.width} {h}" '
                f'width="{self.width}" height="{h}" role="img" aria-label="{esc(title)}">')
        style = ("<style>\n"
                 f"  :root {{ {vars_for(LIGHT)} }}\n"
                 f"  @media (prefers-color-scheme: dark) {{ :root {{ {vars_for(DARK)} }} }}\n"
                 f"  text {{ font-family: {MONO_STACK}; }}\n"
                 "</style>")
        return head + style + "".join(self.parts) + "</svg>"


def panel(cv, x, y, w, h, title, title_color="var(--fg)"):
    cv.rect(x, y, w, h, r=10, fill="var(--panel)", stroke="var(--panel-border)")
    cv.text(x + 14, y + 22, title.upper(), size=10, fill=title_color,
            family=SANS, weight="700")


def table(cv, x, y, name, columns, indexes=(), width=300, subtitle=None,
          notes=()):
    """Draw one table card and return its height.

    columns: list of (name, type, role). Each row keeps the name on the left and
    puts the role badge and type on the right, so columns never collide.
    notes: lines drawn under the card, in the caller's secondary text style.
    """
    n = len(columns)
    header = 36 if subtitle else 30
    index_block = 22 + len(indexes) * 18 if indexes else 0
    h = header + n * ROW_H + index_block + 8

    cv.rect(x, y, width, h, r=10, fill="var(--bg)", stroke="var(--border)", sw=1.5)
    cv.rect(x, y, width, header - 8, r=10, fill="var(--panel)", stroke="none")
    cv.rect(x, y + header - 14, width, 14, r=0, fill="var(--panel)", stroke="none")
    cv.line(x, y + header, x + width, y + header)

    cv.text(x + 12, y + 23, name, size=13, weight="600")
    if subtitle:
        cv.text(x + width - 12, y + 23, subtitle, size=10.5, fill="var(--muted)",
                anchor="end", family=SANS)

    type_right = x + width - 12
    for i, (cname, ctype, role) in enumerate(columns):
        bg, fg, label = role_style(role)
        row_y = y + header + i * ROW_H
        baseline = row_y + 16
        if bg != "none":
            cv.rect(x + 1, row_y + 1, width - 2, ROW_H - 2, r=0, fill=bg, stroke="none")
        cv.text(x + 12, baseline, cname, size=12,
                weight="600" if role == "pk" else "400")
        cv.text(type_right, baseline, ctype, size=11, fill="var(--muted)",
                anchor="end")
        if label:
            cv.text(type_right - len(ctype) * 6.6 - 10, baseline, label, size=9,
                    fill=fg, anchor="end", family=SANS, weight="600")

    if indexes:
        cv.line(x + 1, y + header + n * ROW_H, x + width - 1,
                y + header + n * ROW_H)
        cv.text(x + 12, y + header + n * ROW_H + 15, "INDEXES", size=9.5,
                fill="var(--faint)", family=SANS, weight="600")
        for i, iname in enumerate(indexes):
            cv.text(x + 16, y + header + n * ROW_H + 31 + i * 18,
                    "\u2514 " + iname, size=10.5, fill="var(--idx)")

    for i, note in enumerate(notes):
        cv.text(x, y + h + 18 + i * 15, note, size=10.5, fill="var(--muted)",
                family=SANS)
    return h


def bars(cv, x, y, w, rows, wlabel=96, bw=15, gap=7):
    """Horizontal bars: rows of (label, px_width, display, color).

    Widths are given in pixels by the caller, because the quantities being
    compared do not share one scale (megabytes against buffer counts). The
    display string sits outside the bar, so it stays readable whatever the fill
    color and whether the reader is in light or dark mode.
    """
    top = y
    label_w = int(max(len(r[2]) for r in rows) * 7.4) + 10
    track = w - wlabel - 12 - label_w
    for label, px_width, display, color in rows:
        cv.rect(x, top, wlabel, bw, r=4, fill="var(--bg)", stroke="var(--border)")
        cv.text(x + wlabel / 2, top + 11, label, size=9.5, fill="var(--muted)",
                anchor="middle")
        fill_w = max(3, min(track, int(px_width)))
        cv.bar(x + wlabel + 6, top, fill_w, bw, color, op="0.85")
        cv.text(x + wlabel + 6 + track + 8, top + 11, display, size=10,
                fill="var(--muted)")
        top += bw + gap
    return top - y - gap


def frame(cv, title, subtitle, h):
    cv.rect(0, 0, cv.width, h, r=0, fill="var(--bg)", stroke="none")
    cv.text(PAD, 25, title, size=13.5, family=SANS, weight="600")
    cv.text(PAD, 42, subtitle, size=11, fill="var(--muted)", family=SANS)


def caption(cv, x, y, lines, size=10.5, fill="var(--muted)", line_h=15,
            family=SANS):
    for i, line in enumerate(lines):
        if isinstance(line, tuple):
            text, color = line
            cv.text(x, y + i * line_h, text, size=size, fill=color, family=family)
        else:
            cv.text(x, y + i * line_h, line, size=size, fill=fill, family=family)


def key_values(cv, x, y, pairs, key_w=110, size=10.5, line_h=17):
    """Two aligned columns, so a list of field = value lines stays readable."""
    for i, (key, value) in enumerate(pairs):
        cv.text(x, y + i * line_h, key, size=size, fill="var(--muted)")
        cv.text(x + key_w, y + i * line_h, value, size=size)


# ---------------------------------------------------------- experiment 1

def diagram_query_cost():
    cv = Canvas(NARROW)
    # Heights are the measured content extent plus a little slack; after editing a
    # diagram, run `node autosize.mjs` and copy the printed value back here.
    H = 392
    frame(cv, "Experiment 1 schema: orders",
          "one table, two access paths; the lookup query never changes, only the index portfolio does", H)

    y = 60
    table(cv, PAD, y, "orders",
          [("id", "bigint", "pk"), ("customer_id", "bigint", "join"),
           ("created_at", "timestamp", "plain"), ("payload", "text", "plain")],
          indexes=["orders_customer_id_idx   (customer_id)",
                   "orders_created_at_id_idx  (created_at, id)"],
          width=316,
          notes=["rows = 100,000 / 1,000,000",
                 "payload = repeat('x', 80)"])

    px = PAD + 316 + 26
    pw = cv.width - PAD - px
    panel(cv, px, y, pw, 272, "data shape")
    key_values(cv, px + 14, y + 54, [
        ("rows", ":rows"),
        ("customer_id", "(id * 7919) % (:rows / 100)"),
        ("created_at", "2020-01-01 + id * 1 s"),
        ("payload", "repeat('x', 80)  \u2192  80 bytes"),
    ], key_w=92)

    cv.line(px + 14, y + 142, px + pw - 14, y + 142, stroke="var(--panel-border)")
    caption(cv, px + 14, y + 162, [
        "GREATEST(:rows / 100, 1) distinct keys, so",
        "every key has matches: 1,000 keys at 100k rows",
        "and 10,000 keys at 1M rows.",
    ])

    cv.line(px + 14, y + 206, px + pw - 14, y + 206, stroke="var(--panel-border)")
    cv.text(px + 14, y + 226, "SAME QUERY, TWO PLANS", size=10,
            fill="var(--accent)", family=SANS, weight="700")
    caption(cv, px + 14, y + 246, [
        ("no index   \u2192  Seq Scan   \u2192  test every tuple", "var(--warn)"),
        ("with index \u2192  Index Scan \u2192  descend, then fetch", "var(--toast)"),
    ], size=11)
    caption(cv, px + 14, y + 282, [
        "The result set is identical; the visited",
        "buffers are what changes.",
    ])

    return cv.svg(H, "Experiment 1 schema: the orders table with a customer_id lookup index and a (created_at, id) pagination index")


# ---------------------------------------------------------- experiment 2

def diagram_writes():
    cv = Canvas(WIDE)
    H = 702
    frame(cv, "Experiment 2 schema: five tables for the write path",
          "the same five columns everywhere; only the secondary index portfolio and the target table change", H)

    cols = [("id", "bigint", "pk"), ("customer_id", "bigint", "plain"),
            ("created_at", "timestamp", "plain"), ("status", "text", "plain"),
            ("payload", "text", "plain")]

    cw = 292
    gap = 16
    x0 = PAD
    y1 = 64
    table(cv, x0, y1, "insert_none", cols, [], width=cw,
          notes=["0 secondary indexes: heap and primary",
                 "key only"])
    table(cv, x0 + cw + gap, y1, "insert_one", cols,
          ["insert_one_customer_idx"], width=cw,
          notes=["1 secondary index"])
    table(cv, x0 + 2 * (cw + gap), y1, "insert_three", cols,
          ["insert_three_customer_idx", "insert_three_created_idx",
           "insert_three_status_idx"], width=cw,
          notes=["3 secondary indexes: three extra index",
                 "writes and WAL records per row"])

    y2 = 306
    table(cv, x0, y2, "append_one", cols, ["append_one_customer_idx"], width=cw,
          notes=["same batch, but the table already holds",
                 "1,000,000 rows, so every key now descends",
                 "a taller B-tree"])
    table(cv, x0 + cw + gap, y2, "update_fillfactor", cols, [], width=cw,
          subtitle="fillfactor = 80",
          notes=["20% of each page is left free, so a new",
                 "tuple version can stay on its page"])
    table(cv, x0 + 2 * (cw + gap), y2, "update_default", cols, [], width=cw,
          subtitle="fillfactor = 100",
          notes=["pages are filled completely, so a new",
                 "tuple version usually needs another page"])

    yy = y2 + 252
    cv.line(PAD, yy, cv.width - PAD, yy)
    cv.text(PAD, yy + 24, "ONE MEASURED INSERT, 100,000 ROWS", size=10,
            fill="var(--accent)", family=SANS, weight="700")
    cv.text(PAD, yy + 44, "INSERT INTO \u2026 SELECT g, (g * 7919) % 100000, "
                          "timestamp '2020-01-01' + g * interval '1 second', 'new', repeat('x', 40)",
            size=10.5, fill="var(--muted)")
    cv.text(PAD, yy + 62, "The plan text is identical in all three cases: there is no access path to choose. "
                          "The executor still writes one heap tuple", size=10.5,
            fill="var(--muted)", family=SANS)
    cv.text(PAD, yy + 78, "and one index entry per secondary index per row, plus the matching WAL.",
            size=10.5, fill="var(--muted)", family=SANS)
    cv.text(PAD, yy + 100, "the two update cases change only fillfactor and whether the changed column is indexed",
            size=10, fill="var(--faint)", family=SANS)
    cv.text(PAD, yy + 118, "every case recorded with EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF)",
            size=10, fill="var(--faint)")

    return cv.svg(H, "Experiment 2 schema: insert_none, insert_one, insert_three, append_one, update_fillfactor and update_default")


# ---------------------------------------------------------- experiment 3

def diagram_toast():
    cv = Canvas(NARROW)
    H = 536
    frame(cv, "Experiment 3 schema: two widths of the same table",
          "identical columns and index; only the payload construction and its storage mode differ", H)

    cols = [("id", "bigint", "pk"), ("bucket", "int", "idx"),
            ("created_at", "timestamp", "plain"), ("payload", "text", "toast")]

    y = 60
    cw = 316
    h1 = table(cv, PAD, y, "width_narrow", cols, ["width_narrow_bucket_idx"],
               width=cw, subtitle="50,000 rows",
               notes=["payload = repeat('n', 40)   \u2192  ~40 B, stays on the heap page"])
    cv.text(PAD, y + h1 + 50, "ALTER TABLE width_wide ALTER COLUMN payload SET STORAGE EXTERNAL",
            size=10, fill="var(--accent)", family=SANS)
    table(cv, PAD, y + h1 + 64, "width_wide", cols, ["width_wide_bucket_idx"],
          width=cw, subtitle="50,000 rows",
          notes=["payload = repeat(md5(g::text), 200)  \u2192  ~6.4 kB"])

    px = PAD + cw + 26
    pw = cv.width - PAD - px

    panel(cv, px, y, pw, 176, "where the bytes live")
    bars(cv, px + 14, y + 44, pw - 28, [
        ("heap", 11, "5.06 MB", "var(--idx)"),
        ("heap wide", 8, "3.83 MB", "var(--idx)"),
        ("toast wide", 260, "~414 MB", "var(--toast)"),
    ], wlabel=78)
    caption(cv, px + 14, y + 132, [
        "total: 6.9 MB narrow  versus  419.9 MB wide.",
        "The wide heap is smaller because its values",
        "left the page and grew its TOAST relation.",
        "bars use a shared scale within each chart.",
    ])

    panel(cv, px, y + 194, pw, 226, "what each plan touches, 505 rows")
    bars(cv, px + 14, y + 240, pw - 28, [
        ("id, created_at", 44, "332 buffers / 0.401 ms", "var(--toast)"),
        ("length(payload)", 310, "2,352 buffers / 19.95 ms", "var(--warn)"),
    ], wlabel=100)
    caption(cv, px + 14, y + 312, [
        "STORAGE EXTERNAL disables compression, so this",
        "measures width rather than compressibility.",
        ("SELECT id, created_at    \u2192 heap pages only", "var(--toast)"),
        ("SELECT length(payload)  \u2192 forces TOAST reads", "var(--warn)"),
    ])

    return cv.svg(H, "Experiment 3 schema: width_narrow with a 40 byte payload versus width_wide with a 6.4 kilobyte STORAGE EXTERNAL payload")


# ---------------------------------------------------------- experiment 4

def diagram_archive():
    cv = Canvas(WIDE)
    H = 616
    frame(cv, "Experiment 4 schema: three layouts over the same 2020 data",
          "1,000,000 rows over 365 days; the hot slice (created_at >= 2020-12-01) holds 82,170 rows = 8.22%", H)

    x0, x1 = PAD, cv.width - PAD
    ty = 84
    cw = (x1 - x0) / 12
    cv.text(x0, ty - 12, "MONTHLY DISTRIBUTION", size=10, fill="var(--accent)",
            family=SANS, weight="700")
    for i in range(12):
        hot = i == 11
        cv.rect(x0 + i * cw + 1, ty, cw - 2, 26, r=4,
                fill="var(--warn)" if hot else "var(--panel)",
                stroke="var(--warn)" if hot else "var(--panel-border)",
                op="0.9" if hot else None)
        cv.text(x0 + i * cw + cw / 2, ty + 17, f"{i + 1:02d}", size=9.5,
                anchor="middle", fill="var(--bg)" if hot else "var(--muted)",
                weight="700" if hot else "400")
    cv.line(x0 + 11 * cw, ty - 6, x0 + 11 * cw, ty + 34, stroke="var(--warn)", dash="3 3")
    cv.text(x0, ty + 48, "cold: 91.78% of rows, rarely read", size=10.5,
            fill="var(--muted)", family=SANS)
    cv.text(x1, ty + 48, "hot: 8.22% of rows", size=10.5, fill="var(--warn)",
            anchor="end", family=SANS, weight="600")

    y = 156
    cols = [("id", "bigint", "pk"), ("created_at", "timestamp", "join"),
            ("customer_id", "bigint", "plain"), ("payload", "text", "plain")]
    cw2 = 292
    gap = 16

    d = table(cv, PAD, y, "archive_full", cols,
              ["archive_full_created_idx", "  (created_at, id)"],
              width=cw2, subtitle="one heap",
              notes=["one index covering all 12 months"])
    table(cv, PAD + cw2 + gap, y, "archive_full_partialindex", cols,
          ["archive_full_partial_created_idx", "  (created_at, id)",
           "  WHERE created_at >= 2020-12-01"],
          width=cw2, subtitle="one heap",
          notes=["same rows, index stores 8.22% of keys"])
    table(cv, PAD + 2 * (cw2 + gap), y, "archive_part", cols,
          ["archive_part_created_idx  (created_at, id)"],
          width=cw2, subtitle="PARTITION BY RANGE",
          notes=["archive_part_2020_01 \u2026 archive_part_2020_12",
                 "12 partitions, one index each"])

    yy = y + d + 62
    cv.line(PAD, yy, cv.width - PAD, yy)
    cv.text(PAD, yy + 22, "SIZE OF THE created_at STRUCTURE", size=10,
            fill="var(--accent)", family=SANS, weight="700")
    bars(cv, PAD, yy + 34, 520, [
        ("full", 288, "31.6 MB", "var(--warn)"),
        ("partial", 24, "2.6 MB", "var(--toast)"),
        ("partitioned", 316, "34.6 MB total", "var(--idx)"),
    ], wlabel=100)

    caption(cv, PAD, yy + 118, [
        "The partial index only stores keys that can match its predicate, so it is",
        "small to cache and maintain. Partitioning trades one large structure for",
        "twelve small ones and enables pruning, at a small total-size overhead.",
        ("recent query (ordered LIMIT 50) \u2192 ~4 buffers in all three layouts", "var(--faint)"),
        ("cold Jan\u2013Jun query \u2192 6 partitions appended, the other 6 pruned", "var(--faint)"),
    ])

    return cv.svg(H, "Experiment 4 schema: archive_full, archive_full_partialindex and archive_part layouts for hot and cold data")


# ---------------------------------------------------------- experiment 5

def diagram_concurrency():
    cv = Canvas(NARROW)
    H = 410
    frame(cv, "Experiment 5 schema: one table under concurrent point access",
          "pgbench drives random primary-key reads and updates; only the row count changes between runs", H)

    y = 60
    table(cv, PAD, y, "bench_orders",
          [("id", "bigint", "pk"), ("customer_id", "bigint", "join"),
           ("created_at", "timestamp", "plain"), ("payload", "text", "plain"),
           ("counter", "bigint", "plain")],
          ["bench_orders_customer_idx  (customer_id)"],
          width=316, subtitle="fillfactor = 80",
          notes=["rows = 100,000 or 1,000,000",
                 "INSERT \u2026 SELECT g, (g * 7919) % 100000,",
                 "  2020-01-01 + g * 1 s, repeat('x', 40)"])

    px = PAD + 316 + 26
    pw = cv.width - PAD - px

    panel(cv, px, y, pw, 122, "the workload")
    caption(cv, px + 14, y + 50, [
        ("\\set id random(1, :rows)", "var(--fg)"),
        ("SELECT \u2026 WHERE id = :id;", "var(--idx)"),
        ("UPDATE \u2026 SET counter = counter + 1", "var(--idx)"),
        ("  WHERE id = :id;", "var(--idx)"),
    ])
    caption(cv, px + pw - 14 - 150, y + 50, [
        "1 and 8 clients",
        "5 s per case",
        "after pg_stat_reset()",
        "protocol=prepared",
    ], fill="var(--muted)")

    panel(cv, px, y + 140, pw, 190, "does the working set fit in shared buffers?",
          "var(--warn)")
    bx = px + 14
    bw2 = pw - 28

    bar_w = bw2 - 96 - 178
    cv.text(bx, y + 182, "100,000 rows", size=10.5, fill="var(--muted)")
    cv.bar(bx + 96, y + 172, bar_w, 13, "var(--toast)", op="0.85")
    cv.text(bx + 96 + bar_w + 10, y + 182, "0 / 134,811 heap reads", size=10,
            fill="var(--muted)")

    cv.text(bx, y + 210, "1,000,000 rows", size=10.5, fill="var(--muted)")
    cv.bar(bx + 96, y + 200, bar_w * 0.14, 13, "var(--warn)", op="0.85")
    cv.bar(bx + 96 + bar_w * 0.14, y + 200, bar_w * 0.86, 13, "var(--toast)", op="0.85")
    cv.text(bx + 96 + bar_w + 10, y + 210, "25,909 / 142,460 heap reads", size=10,
            fill="var(--muted)")

    cv.line(bx, y + 228, bx + bw2, y + 228, stroke="var(--panel-border)")
    caption(cv, bx, y + 250, [
        "The larger working set no longer fits, so heap",
        "pages are read. Read TPS still stayed near",
        "27\u201328k at one client, because those pages come",
        "from tmpfs. The counters show the cache effect;",
        "elapsed time moves with the storage underneath.",
    ])

    return cv.svg(H, "Experiment 5 schema: the bench_orders table used by the pgbench read and write scripts")


DIAGRAMS = {
    "query-cost-schema.svg": diagram_query_cost,
    "write-path-schema.svg": diagram_writes,
    "row-width-schema.svg": diagram_toast,
    "archiving-schema.svg": diagram_archive,
    "concurrency-schema.svg": diagram_concurrency,
}

if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    for name, fn in DIAGRAMS.items():
        (here / name).write_text(fn() + "\n", encoding="utf-8")
        print("wrote", here / name)
