"""HomeLine-owned SMS archive, provisioned from the inserted SIM."""
from probe import response
from trial_sms import Archive


class StandaloneArchive(Archive):
    imported_column = 'imported'

    def __init__(self, path, device):
        self.path, self.device = path, device
        with self.connect() as db:
            db.execute('pragma journal_mode=wal')
            db.executescript("""
                create table if not exists sms (
                    id integer primary key autoincrement, imsi text not null, iccid text not null,
                    peer text not null, local_phone text, sender text, recipient text, content text,
                    type integer not null, status integer, timestamp text, created_at text,
                    imported integer not null default 0
                );
                create index if not exists sms_thread on sms(imsi, peer, timestamp, id);
                create index if not exists sms_incoming on sms(type, id);
                create table if not exists sms_contacts (
                    imsi text not null, iccid text not null, peer text not null, last_sms_id integer,
                    last_timestamp text, last_content text, last_type integer, unread_count integer,
                    created_at text, updated_at text, primary key(imsi, peer)
                );
            """)
            if 'imported' not in {column['name'] for column in db.execute('pragma table_info(sms)')}:
                db.execute('alter table sms add column imported integer not null default 0')
            self.prepare_parts(db)

    def bind_sim(self, modem, imsi):
        iccid, = response(modem, 'AT+QCCID', r'\+QCCID:\s*"?([0-9]{18,22})"?')
        self.imsi, self.iccid = imsi, iccid
