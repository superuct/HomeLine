"""Single-SIM AT trial, using the existing HomeLine message archive."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
import secrets
import sqlite3
from urllib.parse import parse_qs, urlsplit

from modem import address, ModemError

GSM = ('@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ'
       ' !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§'
       '¿abcdefghijklmnopqrstuvwxyzäöñüà')
EXT = {10: '\f', 20: '^', 40: '{', 41: '}', 47: '\\', 60: '[', 61: '~', 62: ']', 64: '|', 101: '€'}


def submit(number, text):
    encoded = text.encode('utf-16-be')
    if not encoded or len(encoded) > 1024:
        raise ValueError('Invalid message length')
    target = address(number)
    if len(encoded) <= 140:
        return [b'\x00\x01\x00' + target + b'\x00\x08' + bytes([len(encoded)]) + encoded]
    chunks, chunk = [], b''
    for character in text:
        data = character.encode('utf-16-be')
        if len(chunk) + len(data) > 134:
            chunks.append(chunk)
            chunk = b''
        chunk += data
    chunks.append(chunk)
    ref = secrets.randbelow(256)
    return [b'\x00\x41\x00' + target + b'\x00\x08' + bytes([6 + len(chunk), 5, 0, 3, ref, len(chunks), part]) + chunk
            for part, chunk in enumerate(chunks, 1)]


def septets(data, count, offset=0):
    bits = int.from_bytes(data, 'little')
    values = ((bits >> (offset + position * 7)) & 127 for position in range(count))
    return ''.join(EXT.get(next(values, -1), '�') if value == 27 else GSM[value] for value in values)


def delivered(pdu):
    raw = bytes.fromhex(pdu)
    at = 1 + raw[0]
    flags, count, toa = raw[at:at+3]
    if flags & 3:
        raise ValueError('Unsupported TPDU')
    end = at + 3 + (count + 1) // 2
    sender_data = raw[at+3:end]
    if toa & 0x70 == 0x50:
        sender = septets(sender_data, count * 4 // 7)
    else:
        sender = ''.join(f'{byte:02x}'[::-1] for byte in sender_data)[:count]
        if not re.fullmatch('[0-9]+', sender):
            raise ValueError('Invalid sender')
        if toa & 0x70 == 0x10:
            sender = '+' + sender
    dcs = raw[end+1]
    ts = raw[end+2:end+9]
    dates = [int(f'{x:02x}'[::-1]) for x in ts[:6]]
    offset = 15 * int(f'{ts[6] & 0xf7:02x}'[::-1])
    stamp = datetime(2000 + dates[0], *dates[1:],
                     tzinfo=timezone(timedelta(minutes=-offset if ts[6] & 8 else offset)))
    size = raw[end+9]
    data = raw[end+10:]
    header = 0
    concat = None
    if flags & 0x40:
        header = data[0] + 1
        position = 1
        if header > len(data):
            raise ValueError('Truncated header')
        while position < header:
            kind, length = data[position:position+2]
            position += 2
            element = data[position:position+length]
            position += length
            if (kind, length) in ((0, 3), (8, 4)):
                concat = (int.from_bytes(element[:-2], 'big'), *element[-2:])
                if not 1 <= concat[2] <= concat[1] <= 30:
                    raise ValueError('Invalid multipart index')
        if position != header:
            raise ValueError('Invalid UDH')
    if dcs & 0xC0 == 0 and dcs & 0x2C == 8 or dcs & 0xF0 == 0xE0:
        if size != len(data) or (size - header) % 2:
            raise ValueError('Invalid UCS-2 length')
        body = data[header:].decode('utf-16-be')
    elif dcs & 0xEC == 0 or dcs & 0xF4 in (0xC0, 0xD0, 0xF0):
        skipped = (header * 8 + 6) // 7
        if size < skipped or size * 7 > len(data) * 8:
            raise ValueError('Invalid GSM length')
        body = septets(data, size - skipped, skipped * 7)
    else:
        raise ValueError('Unsupported SMS encoding')
    return sender, stamp, body, concat


def timeline_time(original, recorded, imported):
    for value in ((original, recorded) if imported else (recorded, original)):
        if value is None or value == '':
            continue
        try:
            numeric = float(value)
            if abs(numeric) < 1e15:
                return numeric / 1000 if abs(numeric) > 1e12 else numeric
        except (TypeError, ValueError):
            try:
                return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
            except (TypeError, ValueError, OverflowError):
                pass
    return -62135596800.0


class Archive:
    imported_column = '0'
    def __init__(self, path, device):
        self.path, self.device = path, device
        with self.connect() as db:
            self.imsi, self.iccid = db.execute(
                'select s.imsi,s.iccid from devices d join sim_cards s on d.iccid=s.iccid where d.alias=?',
                (device,)).fetchone()
            self.prepare_parts(db)

    @staticmethod
    def prepare_parts(db):
        db.execute('''create table if not exists homeline_at_inbox (
                imsi text, digest text, sender text, stamp text, ref integer, total integer,
                part integer, body text, complete integer not null default 0, primary key(imsi,digest))''')
        db.execute("update homeline_at_inbox set body='' where complete=1 and body<>''")
        db.execute('''create table if not exists homeline_sms_requests (
                imsi text, request_id text, fingerprint text not null, status integer not null,
                result text not null, primary key(imsi,request_id))''')

    def bind_sim(self, modem, imsi):
        if imsi != self.imsi:
            raise ModemError('Active SIM does not match the message archive')

    def connect(self):
        db = sqlite3.connect(self.path, timeout=3)
        db.row_factory = sqlite3.Row
        db.create_function('homeline_time', 3, timeline_time, deterministic=True)
        db.execute('pragma secure_delete=on')
        return db

    def claim_send(self, request_id, fingerprint):
        with self.connect() as db:
            db.execute('begin immediate')
            row = db.execute('select fingerprint,status,result from homeline_sms_requests where imsi=? and request_id=?',
                             (self.imsi, request_id)).fetchone()
            if row:
                return tuple(row)
            db.execute("insert into homeline_sms_requests values(?,?,?,0,'{}')", (self.imsi, request_id, fingerprint))
        return None

    def finish_send(self, request_id, status, result):
        with self.connect() as db:
            db.execute('update homeline_sms_requests set status=?,result=? where imsi=? and request_id=?',
                       (status, json.dumps(result), self.imsi, request_id))

    def abandon_unstarted_send(self, request_id):
        with self.connect() as db:
            db.execute('delete from homeline_sms_requests where imsi=? and request_id=? and status=0',
                       (self.imsi, request_id))

    def record(self, db, peer, body, outgoing, stamp, status):
        recorded = datetime.now().astimezone().isoformat(' ', timespec='microseconds')
        kind = 2 if outgoing else 1
        number_fields = ('', peer) if outgoing else (peer, '')
        message_id = db.execute('''insert into sms
            (imsi,iccid,peer,local_phone,sender,recipient,content,type,status,timestamp,created_at)
            values(?,?,?,'',?,?,?,?,?,?,?)''',
            (self.imsi, self.iccid, peer, *number_fields, body, kind, status, stamp, recorded)).lastrowid
        db.execute('''insert into sms_contacts(imsi,iccid,peer,last_sms_id,last_timestamp,last_content,
            last_type,unread_count,created_at,updated_at) values(?,?,?,?,?,?,?,?,?,?)
            on conflict(imsi,peer) do update set iccid=excluded.iccid,last_sms_id=excluded.last_sms_id,
            last_timestamp=excluded.last_timestamp,last_content=excluded.last_content,last_type=excluded.last_type,
            unread_count=coalesce(sms_contacts.unread_count,0)+excluded.unread_count,updated_at=excluded.updated_at''',
            (self.imsi, self.iccid, peer, message_id, stamp, body, kind, int(not outgoing), recorded, recorded))
        return message_id

    def ingest(self, pdu):
        sender, stamp, body, concat = delivered(pdu)
        timestamp = stamp.astimezone().isoformat(' ', timespec='seconds')
        digest = hashlib.sha256(bytes.fromhex(pdu)).hexdigest()
        with self.connect() as db:
            db.execute('begin immediate')
            ref, total, part = concat or (-1, 1, 1)
            inserted = db.execute('''insert or ignore into homeline_at_inbox
                (imsi,digest,sender,stamp,ref,total,part,body) values(?,?,?,?,?,?,?,?)''',
                (self.imsi, digest, sender, timestamp, ref, total, part, body)).rowcount
            if not inserted:
                return False
            if concat:
                lower = (stamp.astimezone() - timedelta(minutes=5)).isoformat(' ', timespec='seconds')
                upper = (stamp.astimezone() + timedelta(minutes=5)).isoformat(' ', timespec='seconds')
                parts = db.execute('''select digest,part,body from homeline_at_inbox
                    where imsi=? and sender=? and ref=? and total=? and stamp between ? and ? and complete=0
                    order by part''', (self.imsi, sender, ref, total, lower, upper)).fetchall()
                if [row['part'] for row in parts] != list(range(1, total + 1)):
                    return False
                body = ''.join(row['body'] for row in parts)
                db.executemany("update homeline_at_inbox set complete=1,body='' where imsi=? and digest=?",
                               ((self.imsi, row['digest']) for row in parts))
            else:
                db.execute("update homeline_at_inbox set complete=1,body='' where imsi=? and digest=?", (self.imsi, digest))
            self.record(db, sender, body, False, timestamp, 0)
        return True

    def send(self, modem, number, body, send_part=None):
        pdus = submit(number, body)
        stamp = datetime.now().astimezone().isoformat(' ', timespec='microseconds')
        accepted = 0
        try:
            for pdu in pdus:
                reply = send_part(pdu) if send_part else modem._command(f'AT+CMGS={len(pdu)-1}', pdu=pdu, timeout=30)
                if not any(re.fullmatch(r'\+CMGS:\s*\d+', line) for line in reply):
                    raise ModemError('No submit reference')
                accepted += 1
        except (ModemError, OSError):
            if accepted:
                with self.connect() as db:
                    self.record(db, number, body, True, stamp, 3)
            raise
        with self.connect() as db:
            return self.record(db, number, body, True, stamp, 2)

    def request(self, method, target):
        url = urlsplit(target)
        q = parse_qs(url.query)
        get = lambda key, default='': q.get(key, [default])[0]
        if get('device_id', self.device) != self.device or get('imsi', self.imsi) != self.imsi:
            return 404, {}
        limit = max(1, min(500, int(get('limit', '100'))))
        peer = get('peer')
        with self.connect() as db:
            if method == 'GET' and url.path == '/api/sms/contacts':
                rows = db.execute('''select * from sms_contacts where imsi=?
                    order by updated_at desc,peer limit ?''', (self.imsi, limit)).fetchall()
            elif method == 'GET' and url.path == '/api/sms/thread':
                if get('order') == 'timeline':
                    before = get('before_timeline')
                    cursor = float(before) if before else None
                    rows = db.execute(f'''select sms.*, homeline_time(timestamp,created_at,{self.imported_column}) as timeline_cursor
                        from sms where imsi=? and peer=? and (? is null or (timeline_cursor,id)<(?,?))
                        order by timeline_cursor desc,id desc limit ?''',
                        (self.imsi, peer, cursor, cursor, int(get('before_id','0')), limit)).fetchall()[::-1]
                else:
                    cursor = get('before_ts')
                    rows = db.execute('''select * from sms where imsi=? and peer=?
                        and (?='' or (timestamp,id)<(?,?)) order by timestamp desc,id desc limit ?''',
                        (self.imsi, peer, cursor, cursor, int(get('before_id','0')), limit)).fetchall()[::-1]
            elif method == 'DELETE' and re.fullmatch(r'/api/sms/messages/-?[0-9]+',url.path) and peer:
                db.execute('begin immediate')
                message = db.execute('delete from sms where imsi=? and peer=? and id=?',
                    (self.imsi, peer, int(url.path.rsplit('/',1)[1])))
                if not message.rowcount:
                    return 404, {}
                last = db.execute('select * from sms where imsi=? and peer=? order by id desc limit 1',
                    (self.imsi, peer)).fetchone()
                if last:
                    db.execute('''update sms_contacts set last_sms_id=?,last_timestamp=?,last_content=?,
                        last_type=?,unread_count=min(coalesce(unread_count,0),
                        (select count(*) from sms where imsi=? and peer=? and type=1)),updated_at=?
                        where imsi=? and peer=?''', (last['id'],last['timestamp'],last['content'],last['type'],
                        self.imsi,peer,datetime.now().astimezone().isoformat(' '),self.imsi,peer))
                else:
                    db.execute('delete from sms_contacts where imsi=? and peer=?',(self.imsi,peer))
                return 200, {}
            else:
                return 404, {}
        result = [dict(row, device_id=self.device) for row in rows]
        for row in result:
            if 'imported' in row:
                row['imported'] = bool(row['imported'])
        return 200, result
