#!/usr/bin/env python3
"""Sprint 6C: plot DDMTD event CSVs from the three nominal static-delay runs.

Usage: python3 scripts/plot_results.py results/tb_ddmtd
No RTL assumptions beyond the CSV schemas emitted by ddmtd_monitor and
 ddmtd_uart_checker. Results are simulated, not physical measurements.
"""
import argparse
import csv
import json
import math
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

CASES = (0, 20, 95)
EXPECTED = {0: 0, 20: 200, 95: 950}

def read_csv(path, required):
    if not path.is_file():
        raise FileNotFoundError(f'Missing CSV: {path}; run make characterize first')
    with path.open(newline='') as fh:
        reader = csv.DictReader(fh)
        missing = set(required) - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f'{path}: missing columns {sorted(missing)}')
        return list(reader)

def circ_signed(value, reference):
    return ((value - reference + 500) % 1000) - 500

def save(fig, path):
    fig.tight_layout()
    fig.savefig(path, dpi=170)
    plt.close(fig)
    print(f'  {path}')

def analyze(root):
    outdir = root / 'plots'
    outdir.mkdir(parents=True, exist_ok=True)
    records = {}
    for case in CASES:
        averages = read_csv(root / f'averages_{case}.csv', ['time_ps','avg_phase','tracking_locked'])
        pairs = read_csv(root / f'pairs_{case}.csv', ['time_ps','raw_phase'])
        tags = read_csv(root / f'tags_{case}.csv', ['time_ps','channel','tag'])
        faults = read_csv(root / f'faults_{case}.csv', ['time_ps','event'])
        uart = read_csv(root / f'uart_{case}.csv', ['time_ps','event','phase_value','expected_phase','match','start_ok','stop_ok'])
        times = [int(r['time_ps']) / 1e9 for r in averages]  # ps -> ms
        values = [int(r['avg_phase']) for r in averages]
        errors = [circ_signed(v, EXPECTED[case]) for v in values]
        words = [r for r in uart if r['event'] == 'word']
        bytes_ = [r for r in uart if r['event'] == 'byte']
        if len(words) != len(averages):
            raise ValueError(f'Case {case}: {len(words)} UART words != {len(averages)} averages (incomplete drain?)')
        if any(r['match'] != '1' for r in words):
            raise ValueError(f'Case {case}: UART word mismatch')
        if any(r['start_ok'] != '1' or r['stop_ok'] != '1' for r in bytes_):
            raise ValueError(f'Case {case}: UART framing error')
        if any(int(r['phase_value']) != v for r, v in zip(words, values)):
            raise ValueError(f'Case {case}: UART phase sequence differs from average sequence')
        # Word log timestamps are the SECOND BYTE START, not its completion.
        # Compute completion from the known nominal UART framing (10 bit times).
        bit_ps = 87 * 100_000  # 87 cycles * 100 ns/cycle -> ps
        completion_ps = [int(r['time_ps']) + 10 * bit_ps for r in words]
        latencies_ms = [(end - int(avg['time_ps'])) / 1e9 for end, avg in zip(completion_ps, averages)]
        if any(x < 0 for x in latencies_ms):
            raise ValueError(f'Case {case}: UART completion predates corresponding average')
        records[case] = dict(times=times, values=values, errors=errors, pairs=pairs, tags=tags,
                             faults=faults, uart=uart, words=words, latencies=latencies_ms,
                             summary=dict(delay_ns=case, expected_phase_count=EXPECTED[case],
                                          average_count=len(values), pair_count=len(pairs),
                                          tag_count=len(tags), uart_byte_count=len(bytes_),
                                          uart_word_count=len(words), fault_events=[r['event'].strip() for r in faults],
                                          circular_error_mean_counts=sum(errors)/len(errors) if errors else None,
                                          circular_error_max_abs_counts=max(map(abs, errors)) if errors else None,
                                          uart_latency_mean_ms=sum(latencies_ms)/len(latencies_ms) if latencies_ms else None,
                                          uart_latency_max_ms=max(latencies_ms) if latencies_ms else None))

    fig, ax = plt.subplots(figsize=(9, 4.8))
    for case, r in records.items():
        ax.plot(r['times'], r['values'], marker='o', label=f'{case} ns measured')
        ax.axhline(EXPECTED[case], linestyle=':', linewidth=1)
    ax.set(xlabel='Simulation time (ms)', ylabel='Averaged phase (counts)', title='DDMTD phase versus time — simulated')
    ax.set_ylim(-30, 1030); ax.grid(True, alpha=.3); ax.legend()
    save(fig, outdir / 'phase_vs_time.png')

    fig, ax = plt.subplots(figsize=(9, 4.8))
    for case, r in records.items():
        ax.plot(r['times'], r['errors'], marker='o', label=f'{case} ns')
    ax.axhline(0, linestyle=':', linewidth=1)
    ax.set(xlabel='Simulation time (ms)', ylabel='Signed circular error (counts)', title='DDMTD circular error — simulated')
    ax.grid(True, alpha=.3); ax.legend()
    save(fig, outdir / 'circular_error.png')

    fig, ax = plt.subplots(figsize=(9, 4.8))
    for case, r in records.items():
        p = [int(row['time_ps'])/1e9 for row in r['pairs']]
        a = r['times']
        u = [(int(row['time_ps']) + 10 * 87 * 100_000)/1e9 for row in r['words']]
        ax.scatter(p, [case + 0.0]*len(p), marker='|', s=65, label=f'{case} ns pairs')
        ax.scatter(a, [case + 5.0]*len(a), marker='o', s=18, label=f'{case} ns avg')
        ax.scatter(u, [case + 10.0]*len(u), marker='x', s=28, label=f'{case} ns UART complete')
    ax.set(xlabel='Simulation time (ms)', ylabel='Case lane (ns; offset by event)', title='Pair, average and UART timing — simulated')
    ax.grid(True, alpha=.3); ax.legend(ncol=3, fontsize=8)
    save(fig, outdir / 'event_timing.png')

    fig, ax = plt.subplots(figsize=(9, 4.8))
    for case, r in records.items():
        ax.plot(range(1, len(r['latencies'])+1), [x*1000 for x in r['latencies']], marker='o', label=f'{case} ns')
    ax.set(xlabel='Average / UART word index', ylabel='Estimated UART completion latency (µs)',
           title='Average-valid to UART completion — simulated')
    ax.grid(True, alpha=.3); ax.legend()
    save(fig, outdir / 'uart_latency.png')

    summary = {'note': 'Simulation only. UART completion derived from second-byte start + 10 nominal bit times; not a separately observed stop edge.',
               'cases': {str(case): r['summary'] for case, r in records.items()}}
    (outdir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'  {outdir / "summary.json"}')
    for case, r in records.items():
        s = r['summary']
        print(f'  {case:>2} ns: pairs={s["pair_count"]} averages={s["average_count"]} UART words={s["uart_word_count"]} max|err|={s["circular_error_max_abs_counts"]} counts')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('logdir', nargs='?', type=Path, default=Path('results/tb_ddmtd'))
    args = parser.parse_args()
    try:
        analyze(args.logdir)
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(1, f'ERROR: {exc}\n')

if __name__ == '__main__':
    main()
