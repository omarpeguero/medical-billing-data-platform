#!/usr/bin/env python3
"""Continuous synthetic medical billing source simulator for the supplied billing DDL.

Usage:
  python medical_billing_simulator.py --init-days 365 --interval-seconds 60
  python medical_billing_simulator.py --once
  python medical_billing_simulator.py --verify

Creates ONLY rows in the existing 10 billing tables. Never creates new tables.
Synthetic data only. NOT a medical/claims standard implementation.

A tick is one simulated business hour. Historical backfill is processed by day;
live ticking is scheduled in accelerated simulated time (default 1 hour/minute).
Syncing Airbyte: initial full refresh, then CDC (preferred) or cursor-based
incremental. The latter does not capture hard deletes; this script uses soft
updates and append-only financial transactions instead.
"""
from __future__ import annotations

import argparse
import logging
import math
import os
import random
import re
import sys
import time
from collections import defaultdict
from datetime import UTC, date, datetime, timedelta
from datetime import time as dtime
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

try:
    import psycopg
    from dotenv import load_dotenv
    from faker import Faker
    from psycopg.rows import dict_row
except ImportError as exc:
    raise SystemExit('Install requirements: pip install -r requirements_medical_billing_simulator.txt') from exc

load_dotenv(Path(__file__).with_name('.env'))
LOG = logging.getLogger('medical-billing-simulator')

CENT = Decimal('0.01')

# Fictional payer entities, relative behavior and collection rates.
PAYERS = [
    ('HORIZON_SYN', 'Horizon Commercial (Synthetic)', 'commercial', 0.29, 0.08, 19, .74),
    ('SUMMIT_SYN', 'Summit Health Plan (Synthetic)', 'commercial', 0.23, 0.12, 34, .68),
    ('MEDICARE_SYN', 'Medicare Program (Synthetic)', 'medicare', 0.22, 0.06, 16, .61),
    ('MEDICAID_SYN', 'State Medicaid (Synthetic)', 'medicaid', 0.21, 0.15, 42, .54),
    ('SELFPAY_SYN', 'Self Pay (Synthetic)', 'self_pay', 0.05, 0.0, 5, .85),
]
# Actual-looking procedure codes, but rates are deliberately invented.
SERVICES = [
    ('CPT', '99213', 'Established patient office visit, low/moderate complexity', 'visit', '145.00', 0.27),
    ('CPT', '99214', 'Established patient office visit, moderate complexity', 'visit', '210.00', 0.24),
    ('CPT', '99203', 'New patient office visit, low/moderate complexity', 'visit', '195.00', 0.11),
    ('CPT', '97153', 'Adaptive behavior treatment, technician-administered', '15_min', '34.00', 0.14),
    ('CPT', '97155', 'Adaptive behavior treatment with protocol modification', '15_min', '52.00', 0.08),
    ('CPT', '90834', 'Psychotherapy, 45 minutes', 'visit', '165.00', 0.09),
    ('CPT', '97110', 'Therapeutic exercises', '15_min', '42.00', 0.07),
]
SPECIALTIES = ['Family Medicine', 'Behavioral Health', 'Physical Therapy', 'Psychiatry']
STATES = [('NY', '10977'), ('NJ', '07645'), ('CT', '06901'), ('PA', '19019')]
EVENT_REASONS = [
    ('CO-16', 'Claim/service lacks information needed for adjudication'),
    ('CO-50', 'Non-covered service'),
    ('CO-97', 'Included in another service or procedure'),
    ('CO-197', 'Authorization/precertification absent'),
    ('PR-1', 'Deductible amount'),
]


def money(value):
    return Decimal(str(value)).quantize(CENT, rounding=ROUND_HALF_UP)


def stamp(day: date, hour=14, minute=0):
    return datetime.combine(day, dtime(hour, minute, tzinfo=UTC))


def bounded(x, lo, hi):
    return max(lo, min(hi, x))


def number_of_events(mean, rng):
    """Poisson draw without numpy; normal approximation for larger means."""
    if mean <= 0:
        return 0
    if mean > 30:
        return max(0, round(rng.gauss(mean, math.sqrt(mean))))
    limit, k, product = math.exp(-mean), 0, 1.0
    while product > limit:
        k += 1
        product *= rng.random()
    return k - 1


def weighted_choice(items, weights, rng):
    return rng.choices(items, weights=weights, k=1)[0]


def annualized_daily_volume(day, base_daily, annual_growth):
    # Slow organic growth since launch plus seasonality, weekday and calendar effects.
    years = (day - date(2024, 1, 1)).days / 365.25
    growth = (1 + annual_growth) ** years
    season = {1:.91, 2:.92, 3:1.03, 4:1.04, 5:1.09, 6:1.03,
              7:.89, 8:.94, 9:1.11, 10:1.10, 11:1.00, 12:.82}[day.month]
    weekday = [1.02, 1.12, 1.11, 1.04, .83, .12, .025][day.weekday()]
    return max(0.0, base_daily * growth * season * weekday)


def hour_factor(hour):
    weights = {8:.08, 9:.12, 10:.15, 11:.13, 12:.09, 13:.13,
               14:.13, 15:.10, 16:.05, 17:.02}
    return weights.get(hour, 0.0)


def connect():
    settings = {
        'host': os.getenv('PGHOST', 'localhost'),
        'port': int(os.getenv('PGPORT', '5432')),
        'dbname': os.getenv('PGDATABASE', 'EMR_source'),
        'user': os.getenv('PGUSER', 'postgres'),
        'password': os.getenv('PGPASSWORD', ''),
        'sslmode': os.getenv('PGSSLMODE', 'prefer'),
        'connect_timeout': 12,
        'autocommit': True,
        'row_factory': dict_row,
    }
    return psycopg.connect(**settings)


def validate_schema(conn):
    # Fail quickly, rather than silently writing against a different schema.
    required = {
        'clients': {'client_id', 'client_number', 'client_status'},
        'providers': {'provider_id', 'provider_number', 'practice_name'},
        'payers': {'payer_id', 'payer_code', 'payer_type'},
        'service_codes': {'service_code_id', 'procedure_code', 'unit_type'},
        'billing_entries': {'billing_entry_id', 'entry_number', 'charge_per_unit', 'entry_status'},
        'claims': {'claim_id', 'claim_number', 'claim_status', 'first_submitted_at'},
        'claim_lines': {'claim_line_id', 'billing_entry_id', 'line_status'},
        'claim_events': {'claim_event_id', 'event_type', 'event_at'},
        'payments': {'payment_id', 'claim_line_id', 'transaction_type', 'amount'},
        'adjustments': {'adjustment_id', 'claim_line_id', 'adjustment_type', 'amount'},
    }
    with conn.cursor() as cur:
        cur.execute("""SELECT table_name, column_name FROM information_schema.columns
                       WHERE table_schema = 'billing'""")
        found = defaultdict(set)
        for rec in cur.fetchall():
            found[rec['table_name']].add(rec['column_name'])
        bad = {k: sorted(v - found[k]) for k, v in required.items() if not v <= found[k]}
        if bad:
            raise RuntimeError(f'Incompatible database schema: {bad}. Run supplied DDL in EMR_source.')


def insert_returning(cur, sql, params):
    cur.execute(sql, params)
    return next(iter(cur.fetchone().values()))


def init_reference(cur, fake, rng):
    for code, name, typ, *_ in PAYERS:
        cur.execute("""INSERT INTO billing.payers(payer_code,payer_name,payer_type)
            VALUES (%s,%s,%s) ON CONFLICT (payer_code) DO NOTHING""", (code, name, typ))
    for system, code, desc, unit, price, _ in SERVICES:
        cur.execute("""INSERT INTO billing.service_codes
            (code_system,procedure_code,description,unit_type,default_charge_per_unit,effective_from)
            VALUES (%s,%s,%s,%s,%s,%s) ON CONFLICT(code_system,procedure_code) DO NOTHING""",
            (system, code, desc, unit, price, date(2023,1,1)))
    cur.execute("SELECT count(*) AS n FROM billing.providers WHERE provider_number LIKE 'SYN-P-%%'")
    existing = cur.fetchone()['n']
    if existing == 0:
        for n in range(1, 13):
            state, _ = STATES[(n-1) % len(STATES)]
            cur.execute("""INSERT INTO billing.providers
               (provider_number,provider_name,npi,specialty,practice_name,state_code)
               VALUES(%s,%s,%s,%s,%s,%s)""",
               (f'SYN-P-{n:04d}',fake.name(),None,SPECIALTIES[(n-1)%4],
                f'Synthetic Practice {1+(n-1)//3}', state))
    cur.execute("SELECT count(*) AS n FROM billing.clients WHERE client_number LIKE 'SYN-C-%%'")
    if cur.fetchone()['n'] == 0:
        for n in range(1, 1001):
            state, postal = rng.choice(STATES)
            dob = fake.date_of_birth(minimum_age=2, maximum_age=83)
            cur.execute("""INSERT INTO billing.clients
              (client_number,first_name,last_name,date_of_birth,state_code,postal_code)
              VALUES (%s,%s,%s,%s,%s,%s)""",
              (f'SYN-C-{n:07d}',fake.first_name(),fake.last_name(),dob,state,postal))


def catalog(cur):
    cur.execute("SELECT payer_id,payer_code FROM billing.payers WHERE payer_code LIKE '%%_SYN'")
    payers = {x['payer_code']: x['payer_id'] for x in cur.fetchall()}
    cur.execute("SELECT service_code_id,procedure_code,default_charge_per_unit,unit_type FROM billing.service_codes WHERE effective_from = %s",(date(2023,1,1),))
    services = {x['procedure_code']: x for x in cur.fetchall()}
    cur.execute("SELECT provider_id FROM billing.providers WHERE provider_number LIKE 'SYN-P-%%' AND is_deleted=FALSE AND provider_status='active'")
    providers = [x['provider_id'] for x in cur.fetchall()]
    cur.execute("SELECT client_id FROM billing.clients WHERE client_number LIKE 'SYN-C-%%' AND is_deleted=FALSE AND client_status='active'")
    clients = [x['client_id'] for x in cur.fetchall()]
    if len(payers) < len(PAYERS) or len(services) < len(SERVICES) or not providers or not clients:
        raise RuntimeError('Missing reference data for simulator. Check the synthetic reference records.')
    return payers, services, providers, clients


def grow_master_data(cur, fake, rng, now):
    """Gradually onboard synthetic clients and occasionally add provider capacity."""
    # Once weekly client signups; once per quarter new staff/practice capacity.
    if now.weekday() == 0 and now.hour in (0, 16):
        cur.execute("SELECT count(*) AS n FROM billing.clients WHERE client_number LIKE 'SYN-C-%%'")
        n=cur.fetchone()['n']
        for i in range(rng.randint(2, 7)):
            state, postal = rng.choice(STATES)
            cur.execute("""INSERT INTO billing.clients
             (client_number,first_name,last_name,date_of_birth,state_code,postal_code)
             VALUES (%s,%s,%s,%s,%s,%s) ON CONFLICT(client_number) DO NOTHING""",
             (f'SYN-C-{n+i+1:07d}', fake.first_name(),fake.last_name(),
              fake.date_of_birth(minimum_age=2, maximum_age=83),state,postal))
    if now.day == 1 and now.month in (1,4,7,10) and now.hour in (0,16):
        cur.execute("SELECT count(*) AS n FROM billing.providers WHERE provider_number LIKE 'SYN-P-%%'")
        n=cur.fetchone()['n']
        # Not every quarter increases headcount.
        if rng.random() < .65:
            state, _=rng.choice(STATES)
            cur.execute("""INSERT INTO billing.providers
              (provider_number,provider_name,npi,specialty,practice_name,state_code)
              VALUES(%s,%s,%s,%s,%s,%s) ON CONFLICT(provider_number) DO NOTHING""",
              (f'SYN-P-{n+1:04d}',fake.name(),None,rng.choice(SPECIALTIES),
               f'Synthetic Practice {1+n//3}',state))


def make_entries(cur, rng, now, count, refs):
    _payers, services, providers, clients = refs
    created = 0
    for seq in range(1, count+1):
        entry = f'SYN-E-{now:%Y%m%d%H}-{seq:05d}'
        code = weighted_choice([x[1] for x in SERVICES],[x[5] for x in SERVICES],rng)
        svc = services[code]
        units = rng.choice([2,4,6,8]) if svc['unit_type'] == '15_min' else 1
        # Different charge amounts by practice, observed case-mix, modest variation.
        rate = money(Decimal(svc['default_charge_per_unit']) * Decimal(str(rng.uniform(.88,1.18))))
        status = weighted_choice(['ready','draft','on_hold'],[.92,.05,.03],rng)
        cur.execute("""INSERT INTO billing.billing_entries
           (entry_number,client_id,provider_id,service_code_id,service_date,
            units,charge_per_unit,entry_status,billing_note)
           VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s)
           ON CONFLICT(entry_number) DO NOTHING RETURNING billing_entry_id""",
           (entry,rng.choice(clients),rng.choice(providers),svc['service_code_id'],
            now.date(),units,rate,status,None))
        created += int(cur.fetchone() is not None)
    return created


def evt(cur, claim_id, event_type, now, line_id=None, reason=None, desc=None):
    cur.execute("""INSERT INTO billing.claim_events
      (claim_id,claim_line_id,event_type,event_at,reason_code,reason_description)
      VALUES(%s,%s,%s,%s,%s,%s)""",
      (claim_id,line_id,event_type,now,reason,desc))


def create_claims(cur, rng, now, refs, max_rows=250):
    payers, _, _, _ = refs
    cur.execute("""SELECT e.billing_entry_id,e.client_id,e.provider_id,e.charge_amount,
                          e.service_date, e.entry_status
       FROM billing.billing_entries e
       LEFT JOIN billing.claim_lines l ON l.billing_entry_id=e.billing_entry_id
       WHERE e.entry_status IN ('ready','draft','on_hold') AND e.is_deleted=FALSE
         AND l.claim_line_id IS NULL AND e.service_date <= %s
       ORDER BY e.service_date, e.billing_entry_id LIMIT %s""",(now.date()-timedelta(days=1),max_rows))
    eligible = cur.fetchall()
    groups = defaultdict(list)
    for e in eligible:
        age = (now.date()-e['service_date']).days
        if e['entry_status'] == 'on_hold' and rng.random() > min(.9, .015*age):
            continue
        if e['entry_status'] == 'draft' and rng.random() > min(.94,.12*age):
            continue
        if rng.random() > min(.98,.36+.12*age):
            continue
        groups[(e['client_id'],e['provider_id'],e['service_date'])].append(e)
    made=0
    payer_defs=[p for p in PAYERS]
    for (client,provider,day), entries in groups.items():
        payer = weighted_choice(payer_defs,[p[3] for p in payer_defs],rng)
        new_claim_id = insert_returning(cur,"""INSERT INTO billing.claims
           (claim_number,client_id,provider_id,payer_id,claim_status,first_submitted_at,last_submitted_at)
           VALUES (%s,%s,%s,%s,'submitted',%s,%s) RETURNING claim_id""",
           (f'SYN-CL-{entries[0]["billing_entry_id"]:010d}',client,provider,
            payers[payer[0]],now,now))
        for i,entry in enumerate(entries,1):
            insert_returning(cur,"""INSERT INTO billing.claim_lines
             (claim_id,billing_entry_id,line_number,billed_amount,line_status)
             VALUES(%s,%s,%s,%s,'submitted') RETURNING claim_line_id""",
             (new_claim_id,entry['billing_entry_id'],i,entry['charge_amount']))
            cur.execute("UPDATE billing.billing_entries SET entry_status='billed' WHERE billing_entry_id=%s",(entry['billing_entry_id'],))
        evt(cur,new_claim_id,'submitted',now)
        made+=1
    return made


def update_claim_status(cur, claim_id, status, line_status=None):
    cur.execute('UPDATE billing.claims SET claim_status=%s WHERE claim_id=%s', (status,claim_id))
    if line_status:
        cur.execute('UPDATE billing.claim_lines SET line_status=%s WHERE claim_id=%s',(line_status,claim_id))


def last_event(cur, claim_id):
    cur.execute("""SELECT event_type,event_at FROM billing.claim_events
        WHERE claim_id=%s AND is_deleted=FALSE ORDER BY event_at DESC,claim_event_id DESC LIMIT 1""",(claim_id,))
    return cur.fetchone()


def decision_days(payer_code):
    return next(p[5] for p in PAYERS if p[0]==payer_code)


def settle_claim(cur, rng, claim, now, payer_info):
    """Adjudicate every line once; subsequently collect patient portions separately."""
    payer_code=claim['payer_code']
    propensity = payer_info[payer_code]
    paid_fraction = propensity[6]
    cur.execute("SELECT * FROM billing.claim_lines WHERE claim_id=%s ORDER BY line_number",(claim['claim_id'],))
    lines=cur.fetchall()
    for line in lines:
        billed=money(line['billed_amount'])
        if payer_code=='SELFPAY_SYN':
            allowed=billed
            patient_due=billed
            insurer=money(0)
        else:
            allowed=money(billed * Decimal(str(paid_fraction*rng.uniform(.92,1.08))))
            allowed=min(allowed,billed)
            patient_share = (.0 if payer_code=='MEDICAID_SYN' else
                             rng.choice([.0,.05,.10,.15,.20,.25]))
            patient_due=money(allowed*Decimal(str(patient_share)))
            insurer=allowed-patient_due
        contractual=billed-allowed
        cur.execute("UPDATE billing.claim_lines SET allowed_amount=%s,patient_responsibility_amount=%s WHERE claim_line_id=%s",
                    (allowed,patient_due,line['claim_line_id']))
        if contractual > 0:
            cur.execute("""INSERT INTO billing.adjustments
             (claim_line_id,adjustment_date,posted_at,adjustment_type,amount,adjustment_group_code,adjustment_reason_code,description)
             VALUES(%s,%s,%s,'contractual',%s,'CO','45','Contracted fee schedule difference')""",
             (line['claim_line_id'],now.date(),now,contractual))
        if insurer > 0:
            cur.execute("""INSERT INTO billing.payments
             (claim_line_id,payer_id,payment_source,payment_date,posted_at,amount,transaction_type,reference_number)
             VALUES(%s,%s,'insurance',%s,%s,%s,'payment',%s)""",
             (line['claim_line_id'],claim['payer_id'],now.date(),now,insurer,
              f'SYN-ERA-{claim["claim_id"]:08d}-{line["line_number"]}'))
    if all(Decimal(l['billed_amount'])<=0 for l in lines):
        update_claim_status(cur,claim['claim_id'],'closed','closed')
        evt(cur,claim['claim_id'],'closed',now)
    else:
        # Follow-on patient payment and final statuses handled by collection stage.
        cur.execute("""SELECT COALESCE(SUM(patient_responsibility_amount),0) AS due
                    FROM billing.claim_lines WHERE claim_id=%s""", (claim['claim_id'],))
        due=money(cur.fetchone()['due'])
        if due > 0:
            update_claim_status(cur,claim['claim_id'],'partially_paid','partially_paid')
            evt(cur,claim['claim_id'],'partially_paid',now)
        else:
            update_claim_status(cur,claim['claim_id'],'paid','paid')
            evt(cur,claim['claim_id'],'paid',now)


def collect_patients(cur, rng, claim, now):
    cur.execute("""SELECT l.claim_line_id,l.patient_responsibility_amount,
       COALESCE((SELECT SUM(p.amount) FROM billing.payments p
                 WHERE p.claim_line_id=l.claim_line_id AND p.payment_source='patient' AND NOT p.is_deleted),0) AS already_paid
       FROM billing.claim_lines l WHERE l.claim_id=%s ORDER BY l.claim_line_id""",(claim['claim_id'],))
    lines=cur.fetchall()
    remaining=sum((money(x['patient_responsibility_amount'] or 0)-money(x['already_paid']) for x in lines),money(0))
    if remaining <= 0:
        update_claim_status(cur,claim['claim_id'],'paid','paid')
        evt(cur,claim['claim_id'],'paid',now)
        return True
    if rng.random() < .58:
        for line in lines:
            bal=money(line['patient_responsibility_amount'] or 0)-money(line['already_paid'])
            if bal>0:
                # Some pay partial bills; a later cycle may clear balance.
                amt = bal if rng.random()<.83 else money(bal*Decimal('0.50'))
                if amt>0:
                    cur.execute("""INSERT INTO billing.payments
                       (claim_line_id,payer_id,payment_source,payment_date,posted_at,amount,transaction_type,reference_number)
                       VALUES(%s,NULL,'patient',%s,%s,%s,'payment',%s)""",
                       (line['claim_line_id'],now.date(),now,amt,f'SYN-PAT-{claim["claim_id"]}-{now:%Y%m%d%H}'))
    return False


def work_claims(cur, rng, now, limit=800):
    cur.execute("""SELECT c.claim_id,c.payer_id,c.claim_status,c.first_submitted_at,
             p.payer_code FROM billing.claims c JOIN billing.payers p ON p.payer_id=c.payer_id
       WHERE c.claim_number LIKE 'SYN-CL-%%' AND c.is_deleted=FALSE
         AND c.claim_status IN ('submitted','accepted','pending','rejected','denied','partially_paid')
       ORDER BY c.claim_id LIMIT %s""",(limit,))
    claims=cur.fetchall()
    counts=defaultdict(int)
    payer_info={p[0]:p for p in PAYERS}
    for claim in claims:
        event=last_event(cur,claim['claim_id'])
        if not event: continue
        elapsed=max(0,(now-event['event_at']).total_seconds()/86400)
        status=claim['claim_status']
        payer=payer_info[claim['payer_code']]
        if status=='submitted' and elapsed>=rng.randint(1,4):
            if rng.random()<.045:
                update_claim_status(cur,claim['claim_id'],'rejected','submitted')
                evt(cur,claim['claim_id'],'clearinghouse_rejected',now,None,'A3','Rejected by clearinghouse edit')
                counts['rejected']+=1
            else:
                update_claim_status(cur,claim['claim_id'],'accepted','pending')
                evt(cur,claim['claim_id'],'clearinghouse_accepted',now)
                counts['accepted']+=1
        elif status=='rejected' and elapsed>=rng.randint(2,7):
            update_claim_status(cur,claim['claim_id'],'submitted','submitted')
            cur.execute("UPDATE billing.claims SET last_submitted_at=%s WHERE claim_id=%s",(now,claim['claim_id']))
            evt(cur,claim['claim_id'],'resubmitted',now)
            counts['resubmitted']+=1
        elif status in ('accepted','pending') and elapsed >= max(5, int(rng.gauss(decision_days(claim['payer_code']),5))):
            if rng.random()<payer[4]:
                update_claim_status(cur,claim['claim_id'],'denied','denied')
                reason=rng.choice(EVENT_REASONS)
                evt(cur,claim['claim_id'],'denied',now,None,*reason)
                counts['denied']+=1
            else:
                settle_claim(cur,rng,claim,now,payer_info)
                counts['adjudicated']+=1
        elif status=='denied' and elapsed >= rng.randint(8,22):
            if rng.random() < .68:
                update_claim_status(cur,claim['claim_id'],'submitted','submitted')
                cur.execute("UPDATE billing.claims SET last_submitted_at=%s WHERE claim_id=%s",(now,claim['claim_id']))
                evt(cur,claim['claim_id'],'appealed',now)
                evt(cur,claim['claim_id'],'resubmitted',now+timedelta(seconds=1))
                counts['appealed']+=1
            elif elapsed>100:
                # Finalized uncompensated denial: write off exactly the claim balance.
                cur.execute("SELECT claim_line_id,billed_amount FROM billing.claim_lines WHERE claim_id=%s",(claim['claim_id'],))
                for line in cur.fetchall():
                    cur.execute("""INSERT INTO billing.adjustments
                     (claim_line_id,adjustment_date,posted_at,adjustment_type,amount,adjustment_group_code,adjustment_reason_code)
                     VALUES(%s,%s,%s,'write_off',%s,'CO','50')""",
                     (line['claim_line_id'],now.date(),now,line['billed_amount']))
                update_claim_status(cur,claim['claim_id'],'closed','closed')
                evt(cur,claim['claim_id'],'closed',now)
                counts['written_off']+=1
        elif status=='partially_paid' and elapsed >= rng.randint(10,30):
            fully_paid=collect_patients(cur,rng,claim,now)
            counts['patient_payments' if not fully_paid else 'paid']+=1
            if not fully_paid and elapsed>110:
                # Write off only the remaining patient responsibility, not the original charge.
                cur.execute("""SELECT l.claim_line_id,l.patient_responsibility_amount,
                   COALESCE((SELECT SUM(p.amount) FROM billing.payments p
                     WHERE p.claim_line_id=l.claim_line_id AND p.payment_source='patient' AND NOT p.is_deleted),0) paid
                   FROM billing.claim_lines l WHERE l.claim_id=%s""",(claim['claim_id'],))
                for line in cur.fetchall():
                    balance=money(line['patient_responsibility_amount'] or 0)-money(line['paid'])
                    if balance>0:
                        cur.execute("""INSERT INTO billing.adjustments
                         (claim_line_id,adjustment_date,posted_at,adjustment_type,amount,adjustment_group_code,adjustment_reason_code)
                         VALUES(%s,%s,%s,'write_off',%s,'PR','1')""",
                         (line['claim_line_id'],now.date(),now,balance))
                update_claim_status(cur,claim['claim_id'],'closed','closed')
                evt(cur,claim['claim_id'],'closed',now)
                counts['written_off']+=1
    return dict(counts)


def progress_non_claim_entries(cur,rng, now):
    # Small share of old held/draft charges eventually become ready; no direct deletions.
    cur.execute("""SELECT billing_entry_id,entry_status FROM billing.billing_entries
        WHERE entry_number LIKE 'SYN-E-%%' AND entry_status IN ('draft','on_hold')
        AND service_date <= %s ORDER BY billing_entry_id LIMIT 100""",(now.date()-timedelta(days=5),))
    for row in cur.fetchall():
        if rng.random()<.08:
            cur.execute("UPDATE billing.billing_entries SET entry_status='ready' WHERE billing_entry_id=%s",(row['billing_entry_id'],))


def tick(conn, fake, rng, when, count):
    with conn.transaction(), conn.cursor() as cur:
        grow_master_data(cur,fake,rng,when)
        refs=catalog(cur)
        created=make_entries(cur,rng,when,count,refs)
        progress_non_claim_entries(cur,rng,when)
        claims=create_claims(cur,rng,when,refs)
        status=work_claims(cur,rng,when)
    return {'entries':created,'new_claims':claims,**status}


def latest_simulated_hour(conn):
    with conn.cursor() as cur:
        cur.execute("""SELECT max(entry_number) AS last FROM billing.billing_entries
                    WHERE entry_number LIKE 'SYN-E-%%'""")
        raw=cur.fetchone()['last']
    if raw:
        m=re.match(r'^SYN-E-(\d{10})-\d+$',raw)
        if m:
            return datetime.strptime(m.group(1),'%Y%m%d%H').replace(tzinfo=UTC)
    return None


def backfill(conn, fake, rng, args):
    latest=latest_simulated_hour(conn)
    if latest:
        LOG.info('Existing synthetic entries detected, skipping initial backfill. Latest hour: %s',latest.isoformat())
        return latest
    end=date.today()-timedelta(days=1)
    start=end-timedelta(days=args.init_days-1)
    LOG.info('Backfilling %s days (%s -> %s)',args.init_days,start,end)
    for idx in range(args.init_days):
        day=start+timedelta(days=idx)
        when=stamp(day,16)
        expected=annualized_daily_volume(day,args.base_daily_entries,args.annual_growth)
        count=number_of_events(expected,rng)
        results=tick(conn,fake,rng,when,count)
        if idx%30==0 or idx==args.init_days-1:
            LOG.info('Backfill day %s/%s: %s, new billing entries=%s claims=%s',
                     idx+1,args.init_days,day,results['entries'],results['new_claims'])
    # Some calendar days legitimately have no records. Live begins today anyway.
    return stamp(end,23)


def verify(conn):
    with conn.cursor() as cur:
        for table in ('clients','providers','payers','service_codes','billing_entries',
                      'claims','claim_lines','claim_events','payments','adjustments'):
            cur.execute(f'SELECT count(*) AS n FROM billing.{table}')
            LOG.info('%-20s %9s records',table,cur.fetchone()['n'])
        cur.execute("""SELECT
          COALESCE((SELECT SUM(billed_amount) FROM billing.claim_lines l
                    JOIN billing.claims c ON c.claim_id=l.claim_id
                    WHERE c.claim_number LIKE 'SYN-CL-%%'),0) charges,
          COALESCE((SELECT SUM(amount) FROM billing.payments p
                    JOIN billing.claim_lines l ON l.claim_line_id=p.claim_line_id
                    JOIN billing.claims c ON c.claim_id=l.claim_id
                    WHERE c.claim_number LIKE 'SYN-CL-%%'),0) cash,
          COALESCE((SELECT SUM(amount) FROM billing.adjustments a
                    JOIN billing.claim_lines l ON l.claim_line_id=a.claim_line_id
                    JOIN billing.claims c ON c.claim_id=l.claim_id
                    WHERE c.claim_number LIKE 'SYN-CL-%%'),0) adjustments""")
        x=cur.fetchone()
        LOG.info('Synthetic billed=%s payments=%s adjustments=%s outstanding=%s',
                 x['charges'],x['cash'],x['adjustments'],x['charges']-x['cash']-x['adjustments'])
        cur.execute("""SELECT count(*) AS n FROM (
          SELECT l.claim_line_id,l.billed_amount - COALESCE((SELECT SUM(p.amount) FROM billing.payments p
            WHERE p.claim_line_id=l.claim_line_id),0) - COALESCE((SELECT SUM(a.amount) FROM billing.adjustments a
            WHERE a.claim_line_id=l.claim_line_id),0) AS balance
          FROM billing.claim_lines l JOIN billing.claims c ON l.claim_id=c.claim_id
          WHERE c.claim_number LIKE 'SYN-CL-%%') v WHERE balance < -0.01""")
        n=cur.fetchone()['n']
        LOG.info('Overpaid claim lines (should be 0): %s',n)
        if n: raise RuntimeError('Financial validation failed: negative claim line balance')


def main():
    p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--init-days',type=int,default=365,help='Historical backfill days on an empty synthetic source (default: 365)')
    p.add_argument('--interval-seconds',type=float,default=60,help='Real seconds between live ticks (default: 60)')
    p.add_argument('--hours-per-tick',type=int,choices=[1,2,4,6,12,24],default=1,help='Simulated hours per tick (default: 1)')
    p.add_argument('--base-daily-entries',type=float,default=24,help='Baseline weekday synthetic service volume')
    p.add_argument('--annual-growth',type=float,default=.12,help='Business volume annual trend e.g. 0.12')
    p.add_argument('--seed',type=int,default=107,help='Random generator seed for approximate repeatability')
    p.add_argument('--once',action='store_true',help='Run exactly one live tick and exit')
    p.add_argument('--verify',action='store_true',help='Only verify source counts and financial totals')
    args=p.parse_args()
    if args.init_days<1 or args.interval_seconds<=0 or args.base_daily_entries<0 or not (-.5<=args.annual_growth<=1):
        p.error('Invalid volume, backfill, growth or timing argument')
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    rng=random.Random(args.seed)
    fake=Faker('en_US')
    fake.seed_instance(args.seed)
    try:
        with connect() as conn:
            validate_schema(conn)
            if args.verify:
                verify(conn); return
            with conn.transaction(), conn.cursor() as cur:
                init_reference(cur,fake,rng)
            last=backfill(conn,fake,rng,args)
            # Backfill ends yesterday. Resume from observed entries if they are already newer.
            if last.date()<date.today():
                current=stamp(date.today(),0)
            else:
                current=last+timedelta(hours=args.hours_per_tick)
            LOG.info('Live generator running. Current simulated clock=%s, %ss per %s simulated hour(s)',
                     current.isoformat(),args.interval_seconds,args.hours_per_tick)
            while True:
                daily=annualized_daily_volume(current.date(),args.base_daily_entries,args.annual_growth)
                if args.hours_per_tick==24:
                    expected=daily
                else:
                    expected=sum(daily*hour_factor((current.hour+h)%24) for h in range(args.hours_per_tick))
                count=number_of_events(expected,rng)
                results=tick(conn,fake,rng,current,count)
                LOG.info('simulated=%s incoming=%s | %s',current.isoformat(),count,results)
                if args.once: break
                current+=timedelta(hours=args.hours_per_tick)
                time.sleep(args.interval_seconds)
    except KeyboardInterrupt:
        LOG.info('Stopped by user; committed rows are preserved for incremental ingestion.')
    except psycopg.Error as e:
        LOG.error('PostgreSQL error %s: %s',getattr(e,'sqlstate',None),e)
        sys.exit(2)

if __name__=='__main__':
    main()
