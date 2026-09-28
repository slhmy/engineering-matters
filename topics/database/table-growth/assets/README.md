# Assets

Diagrams for the topic README. Each one shows the tables and indexes a single
experiment creates, so the reader can see the shape under test before reading the
numbers.

| File | Purpose |
| --- | --- |
| `query-cost-schema.svg` | The `orders` table with its lookup and pagination indexes. |
| `write-path-schema.svg` | The five tables of the write path, differing only in secondary indexes and fillfactor. |
| `row-width-schema.svg` | Narrow versus `STORAGE EXTERNAL` wide payloads, with the storage split. |
| `archiving-schema.svg` | Full, partial, and partitioned layouts for the hot and cold slices. |
| `concurrency-schema.svg` | The `bench_orders` table and the two `pgbench` statements. |

## Regenerating

The diagrams are generated, not hand-drawn, because the sizes and index names
must agree with `benchmark/sql/*.sql`.

```bash
cd topics/database/table-growth/assets
python3 make-diagrams.py   # write the five SVGs
node measure.mjs           # report the drawn extent of each diagram
node autosize.mjs          # raise any canvas that clips its content
```

When a benchmark changes a column, index, or measured size, update the matching
`diagram_*` function in `make-diagrams.py` and re-run the three commands. The
edit usually means a few lines: a column tuple, an index name in a list, or a
number inside a `bars(...)` call.

`make-diagrams.py` needs only the Python standard library. `measure.mjs` and
`autosize.mjs` drive headless Chrome to compute the union bounding box of the
drawn elements; point `CHROME` at another Chromium binary if Chrome is not at the
default macOS location.

## Conventions

- SVG, not PNG, so the diagrams stay diffable and scale on any display.
- Colors come from CSS custom properties with a `prefers-color-scheme: dark`
  override, so the diagrams follow the reader's theme without a second file.
- Column rows use fixed lanes: identifier on the left, role badge then type on
  the right, so the columns cannot overlap however long a name gets.
- Role badges mark the meaning of a column in that experiment: `PRIMARY KEY`
  (every table), `JOIN KEY` (the column predicates filter on), `INDEX` (has a
  secondary index), and `STORAGE` (`STORAGE EXTERNAL`, values move out of line).
- Bar charts use a shared scale within a chart, but the widths are given in
  pixels rather than computed from the values, because a diagram often compares
  quantities that do not share a unit, such as megabytes against buffer counts.
  The number is printed beside each bar so the reader never has to measure it.
- Canvas heights are the measured content extent. After editing a diagram, run
  `node autosize.mjs` and copy the printed height back into the `H = ...` line of
  that function, then re-run `python3 make-diagrams.py`; the generator writes the
  constant into the file, and a later regeneration would otherwise restore the
  old value.
