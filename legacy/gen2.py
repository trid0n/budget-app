import json

months = json.load(open('/home/claude/months.json'))
other = json.load(open('/home/claude/other.json'))

SEED_MONTHS = {}
for k, v in months.items():
    SEED_MONTHS[k] = {
        'income': [{'name': i['name'], 'amount': i['amount']} for i in v['income']],
        'categories': [
            {
                'name': c['name'],
                'items': [
                    {'name': i['name'], 'assigned': i['amount'], 'activity': i['amount']}
                    for i in c['items']
                ]
            }
            for c in v['categories']
        ],
        'notes': v['comments'] or ''
    }

SEED_OTHER = {
    'techItems': [{'id': f"tech_{i}", 'name': t['name'], 'cost': t['cost'], 'lifespan': t['lifespan']} for i, t in enumerate(other['techItems'])],
    'grocery': {
        'items': [{'id': f"g_{i}", 'name': s['name'], 'cost': s['cost'], 'breakdown': [{'id': f"g_{i}_bd_{j}", 'name': b['name'], 'cost': b['cost']} for j, b in enumerate(s.get('breakdown', []))]} for i, s in enumerate(other['grocery']['staples'] + other['grocery']['other'])],
        'days': other['grocery']['daysInMonth'] or 30,
        'eatOut': 5
    },
    'ballet': {'cost': 174, 'dateCharged': '2026-07-01', 'balance': 261},
    'mtg': {
        'rows': [{'id': f"m_{i}", **row} for i, row in enumerate(other['mtg']['rows'])],
    }
}

MONTHS_JSON = json.dumps(SEED_MONTHS, separators=(',', ':'))
OTHER_JSON = json.dumps(SEED_OTHER, separators=(',', ':'))

print('months json bytes', len(MONTHS_JSON))
print('other json bytes', len(OTHER_JSON))

template = open('/home/claude/template2.html').read()
out = template.replace('__MONTHS_JSON__', MONTHS_JSON).replace('__OTHER_JSON__', OTHER_JSON)
with open('/home/claude/budget-assign.html', 'w') as f:
    f.write(out)
print('written', len(out), 'bytes')
