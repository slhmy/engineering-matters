DROP TABLE IF EXISTS jobs;
DROP TABLE IF EXISTS accounts;

CREATE TABLE accounts (
    id integer PRIMARY KEY,
    balance integer NOT NULL
);

CREATE TABLE jobs (
    id integer PRIMARY KEY,
    status text NOT NULL,
    claimed_by text
);

INSERT INTO accounts (id, balance) VALUES (1, 100), (2, 200);
INSERT INTO jobs (id, status) VALUES (1, 'pending'), (2, 'pending'), (3, 'pending');
