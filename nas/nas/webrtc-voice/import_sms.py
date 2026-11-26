"""Import an existing HomeLine-compatible archive into a new standalone database."""
import argparse
from pathlib import Path

from radio import StandaloneArchive


def import_messages(source, target, device):
    if not source.is_file() or source.resolve() == target.resolve():
        raise ValueError('Specify an existing source and a separate target')
    archive = StandaloneArchive(target, device)
    counts = {}
    with archive.connect() as db:
        db.execute('attach database ? as previous', (source.resolve().as_uri() + '?mode=ro',))
        db.execute('begin immediate')
        if db.execute('select exists(select 1 from sms)').fetchone()[0]:
            raise ValueError('The destination already contains messages')
        for table in ('sms', 'sms_contacts', 'homeline_at_inbox'):
            if not db.execute('select 1 from previous.sqlite_master where type=? and name=?', ('table', table)).fetchone():
                if table == 'homeline_at_inbox':
                    continue
                raise ValueError(f'Missing source table: {table}')
            keys = [row['name'] for row in db.execute(f'pragma main.table_info({table})')]
            source_keys = {row['name'] for row in db.execute(f'pragma previous.table_info({table})')}
            columns = ','.join(keys)
            source_columns = ','.join('1' if key == 'imported' and key not in source_keys else key for key in keys)
            db.execute(f'insert into main.{table} ({columns}) select {source_columns} from previous.{table}')
            counts[table] = db.execute(f'select count(*) from main.{table}').fetchone()[0]
        db.execute("update main.homeline_at_inbox set body='' where complete=1")
        previous = db.execute("select 1 from previous.sqlite_master where name='sqlite_sequence'").fetchone()
        if previous:
            sequence = db.execute("select seq from previous.sqlite_sequence where name='sms'").fetchone()
            if sequence:
                current = db.execute("select seq from main.sqlite_sequence where name='sms'").fetchone()
                db.execute("delete from main.sqlite_sequence where name='sms'")
                db.execute("insert into main.sqlite_sequence(name,seq) values('sms',?)",
                           (max(sequence[0], current[0] if current else 0),))
    return counts


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    parser.add_argument('--device', default='ec20')
    options = parser.parse_args()
    print(import_messages(options.source, options.target, options.device))
