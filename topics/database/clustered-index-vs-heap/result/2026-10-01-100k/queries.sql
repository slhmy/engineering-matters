SELECT id, bucket, payload FROM rows_seq WHERE id >= 50000 AND id < 51000;
SELECT id, bucket, payload FROM rows_seq WHERE bucket = 42;
SELECT id, bucket FROM rows_seq WHERE bucket = 42;
SELECT id, bucket, payload FROM rows_shuffled WHERE id >= 50000 AND id < 51000;
SELECT id, bucket, payload FROM rows_shuffled WHERE bucket = 42;
SELECT id, bucket FROM rows_shuffled WHERE bucket = 42;
