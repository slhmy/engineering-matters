import tempfile
import unittest
from pathlib import Path
import lab


class LabTests(unittest.TestCase):
    def test_order(self):
        self.assertEqual(lab.ids(2000, False), list(range(1, 2001)))
        shuffled = lab.ids(2000, True)
        self.assertEqual(sorted(shuffled), list(range(1, 2001)))
        self.assertNotEqual(shuffled, lab.ids(2000, False))
        self.assertEqual(shuffled, lab.ids(2000, True))

    def test_data(self):
        self.assertEqual(len(lab.row(42)[2]), 256)
        cs = lab.cases(100000, 1000)
        self.assertEqual(len(cs['pk_range_payload'][2]), 1000)
        self.assertEqual(len(cs['secondary_payload'][2]), 100)
        self.assertEqual([r[:2] for r in cs['secondary_payload'][2]], cs['secondary_covering'][2])
        rows = [lab.row(1), lab.row(2)]
        self.assertEqual(lab.fingerprint(rows), lab.fingerprint(reversed(rows)))
        self.assertEqual(lab.fingerprint(rows), lab.fingerprint([list(map(str, r)) for r in rows]))

    def test_generate(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            manifest = lab.generate(p, 2000, 100)
            self.assertEqual(manifest['full_table']['rows'], 2000)
            pg, my = [(p / f'{engine}-load.sql').read_text() for engine in ('pg', 'mysql')]
            self.assertEqual(pg.count('INSERT INTO'), 4)
            self.assertEqual(my.count('INSERT INTO'), 4)
            self.assertEqual(pg.count('VACUUM (ANALYZE)'), 2)
            self.assertEqual(my.count('ENGINE=InnoDB'), 2)
            self.assertNotIn('DROP ', pg + my)
            self.assertEqual([l for l in pg.splitlines() if l.startswith('(')],
                             [l for l in my.splitlines() if l.startswith('(')])

    def test_parsers(self):
        # Synthetic plan fixtures test grammar only; never presented as measurements.
        pg = '[{"Plan":{"Actual Rows":1000,"Actual Loops":1},"Execution Time":1.23}]'
        my = '-> Index range scan (actual time=0.012..1.23 rows=1000 loops=1)'
        self.assertEqual(lab.metrics('pg', pg)['server_ms'], 1.23)
        self.assertEqual(lab.metrics('mysql', my)['root_rows'], 1000)
        with self.assertRaises(ValueError):
            lab.metrics('mysql', 'unexpected output')
        nested = my + '\n    -> child (actual time=0.001..0.42 rows=1000 loops=1)'
        self.assertEqual(lab.metrics('mysql', nested)['server_ms'], 1.23)
        with self.assertRaises(ValueError):
            lab.metrics('mysql', '-> root (never executed)\n    ' + my)
        scientific = '-> scan (actual time=1.23e-3..2.5e+1 rows=1e+6 loops=1)'
        self.assertEqual(lab.metrics('mysql', scientific)['root_rows'], 1000000)


if __name__ == '__main__':
    unittest.main()
