# loadgen.py v1.0.0 - sustained-load client for llama-server (stdlib only).
# Runs N concurrent workers for D seconds against /v1/chat/completions with streaming,
# logs one JSON line per request (TTFT, tokens, server timings, errors) and prints a summary.
# The API key is read from a file and never printed.
import argparse, http.client, json, threading, time, statistics, sys

PROMPT = ('Write a detailed step-by-step guide to configuring a static IP address on Ubuntu Server '
          'using netplan, including the YAML file, how to apply it, and verification commands.')

def one_request(host, port, key, max_tokens, timeout):
    body = json.dumps({
        'messages': [{'role': 'user', 'content': PROMPT}],
        'max_tokens': max_tokens, 'temperature': 0, 'seed': 1729, 'cache_prompt': False,
        'stream': True, 'chat_template_kwargs': {'enable_thinking': False},
    })
    hdr = {'Content-Type': 'application/json'}
    if key:
        hdr['Authorization'] = 'Bearer ' + key
    rec = {'t0': time.time()}
    t0 = time.perf_counter()
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request('POST', '/v1/chat/completions', body, hdr)
        r = conn.getresponse()
        rec['status'] = r.status
        if r.status != 200:
            rec['error'] = r.read(300).decode('utf-8', 'replace')
            return rec
        ttft = None; timings = None; chunks = 0; finish = None
        while True:
            line = r.readline()
            if not line:
                break
            line = line.strip()
            if not line.startswith(b'data:'):
                continue
            data = line[5:].strip()
            if data == b'[DONE]':
                break
            ev = json.loads(data)
            if 'timings' in ev:
                timings = ev['timings']
            for ch in ev.get('choices', []):
                if ch.get('delta', {}).get('content'):
                    chunks += 1
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                if ch.get('finish_reason'):
                    finish = ch['finish_reason']
        rec['ttft'] = ttft
        rec['chunks'] = chunks
        rec['finish'] = finish
        if timings:
            rec['n_gen'] = timings.get('predicted_n')
            rec['gen_tps'] = timings.get('predicted_per_second')
            rec['n_prompt'] = timings.get('prompt_n')
            rec['prompt_tps'] = timings.get('prompt_per_second')
        if finish is None:
            rec['error'] = 'stream ended without finish_reason'
    except Exception as e:
        rec['error'] = type(e).__name__ + ': ' + str(e)
    finally:
        rec['total'] = time.perf_counter() - t0
        conn.close()
    return rec

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', required=True); ap.add_argument('--port', type=int, required=True)
    ap.add_argument('--key-file'); ap.add_argument('--concurrency', type=int, default=1)
    ap.add_argument('--seconds', type=int, default=1800); ap.add_argument('--max-tokens', type=int, default=400)
    ap.add_argument('--timeout', type=int, default=300); ap.add_argument('--log', required=True)
    ap.add_argument('--label', default='')
    a = ap.parse_args()
    key = open(a.key_file).read().strip() if a.key_file else None
    lock = threading.Lock(); recs = []
    deadline = time.time() + a.seconds
    logf = open(a.log, 'a', encoding='utf-8')

    def worker(i):
        while time.time() < deadline:
            rec = one_request(a.host, a.port, key, a.max_tokens, a.timeout)
            rec['worker'] = i; rec['label'] = a.label; rec['conc'] = a.concurrency
            with lock:
                recs.append(rec); logf.write(json.dumps(rec) + '\n'); logf.flush()
            if 'error' in rec:
                time.sleep(2)

    def progress():
        last = 0
        while time.time() < deadline:
            time.sleep(60)
            with lock:
                new = recs[last:]; last = len(recs)
            ok = [r for r in new if 'error' not in r]
            err = len(new) - len(ok)
            tps = statistics.mean([r['gen_tps'] for r in ok if r.get('gen_tps')] or [0])
            print(f'[{a.label}] {time.strftime("%H:%M:%S")} +{len(new)} req, {err} err, mean gen {tps:.1f} tok/s', flush=True)

    t_start = time.time()
    ths = [threading.Thread(target=worker, args=(i,)) for i in range(a.concurrency)]
    threading.Thread(target=progress, daemon=True).start()
    for t in ths: t.start()
    for t in ths: t.join()
    wall = time.time() - t_start
    ok = [r for r in recs if 'error' not in r]
    errs = [r for r in recs if 'error' in r]
    def pct(xs, p):
        xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else None
    tt = [r['ttft'] for r in ok if r.get('ttft') is not None]
    gt = [r['gen_tps'] for r in ok if r.get('gen_tps')]
    summ = {
        'label': a.label, 'concurrency': a.concurrency, 'wall_s': round(wall, 1),
        'requests': len(recs), 'ok': len(ok), 'errors': len(errs),
        'error_kinds': sorted({r['error'][:80] for r in errs}),
        'gen_tps_per_req_mean': round(statistics.mean(gt), 1) if gt else None,
        'gen_tps_per_req_min': round(min(gt), 1) if gt else None,
        'gen_tps_per_req_max': round(max(gt), 1) if gt else None,
        'aggregate_gen_tps': round(sum(r.get('n_gen') or 0 for r in ok) / wall, 1),
        'ttft_p50_ms': round(pct(tt, 0.5) * 1000) if tt else None,
        'ttft_p95_ms': round(pct(tt, 0.95) * 1000) if tt else None,
        'ttft_max_ms': round(max(tt) * 1000) if tt else None,
        'total_max_s': round(max(r['total'] for r in recs), 1) if recs else None,
        'first_10min_gen_tps': round(statistics.mean([r['gen_tps'] for r in ok if r.get('gen_tps') and r['t0'] < t_start + 600] or [0]), 1),
        'last_10min_gen_tps': round(statistics.mean([r['gen_tps'] for r in ok if r.get('gen_tps') and r['t0'] > t_start + wall - 600] or [0]), 1),
    }
    print('SUMMARY ' + json.dumps(summ), flush=True)
    logf.write(json.dumps({'summary': summ}) + '\n'); logf.close()

if __name__ == '__main__':
    main()
