DROP TABLE IF EXISTS account;
DROP TABLE IF EXISTS doctors;
DROP FUNCTION IF EXISTS wait_for_barrier(integer, integer);

CREATE TABLE account (
    id integer PRIMARY KEY,
    balance integer NOT NULL
);

CREATE TABLE doctors (
    name text PRIMARY KEY,
    on_call boolean NOT NULL
);

INSERT INTO account VALUES (1, 100);
INSERT INTO doctors VALUES ('alice', true), ('bob', true);

CREATE FUNCTION wait_for_barrier(barrier_id integer, participants integer)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    arrived integer;
    deadline timestamptz := clock_timestamp() + interval '10 seconds';
BEGIN
    PERFORM pg_advisory_lock_shared(4242, barrier_id);

    LOOP
        SELECT count(*)
        INTO arrived
        FROM pg_locks
        WHERE locktype = 'advisory'
          AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND classid = 4242
          AND objid = barrier_id
          AND mode = 'ShareLock'
          AND granted;

        IF arrived >= participants THEN
            -- Keep both participants present long enough for each waiter to observe the rendezvous.
            PERFORM pg_sleep(0.05);
            RETURN;
        END IF;

        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'barrier % timed out: expected %, found %',
                barrier_id, participants, arrived
                USING ERRCODE = '57014';
        END IF;

        PERFORM pg_sleep(0.01);
    END LOOP;
END;
$$;
