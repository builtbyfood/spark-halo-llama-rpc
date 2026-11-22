# Results: the guide's "Not yet tested" list

Run 2026-11-21 on the same two machines as the guide. Each section gives the prediction written before the run, then what was measured.

Background load during every test unless stated otherwise: a separate production app was running on both machines: its 35B loaded and idle on the Halo (about 36 GB of GPU memory), and its three llama-server processes loaded on the Spark (about 40 GB). Below it's called "the resident app". Its own measurements were paused for these runs.

## A1. Spark-hosted server with an API key, under sustained load

**Setup.** `llama-server` b12477 (`054a1babf`) on the Spark, Qwen3.6-35B-A3B Q8_0, bound to 10.10.10.2:8097:

```
LD_LIBRARY_PATH=. ./llama-server -m Qwen_Qwen3.6-35B-A3B-Q8_0.gguf -ngl 99 \
  --host 10.10.10.2 --port 8097 --ctx-size 32768 -np 4 --flash-attn on \
  --api-key-file ~/halo-tuning/a1-api-key.txt
```

Client: `loadgen.py` (`scripts/loadgen.py`) on the Halo, 30 minutes each at 1, 2 and 4 concurrent streaming requests. Every request uses the guide's fixed netplan prompt (46 tokens), 400 output tokens, temperature 0, `cache_prompt: false`.

**Prediction** (written after a 45-second smoke test at concurrency 2, which gave 53.4 tok/s per request):
- Concurrency 1: about 60 tok/s, close to the guide's 60.8. TTFT under 200 ms.
- Concurrency 2: about 53 tok/s per request, about 105 aggregate.
- Concurrency 4: 38 to 42 tok/s per request, 150 to 165 aggregate.
- No errors. Less than 5% slowdown from the first 10 minutes to the last. The Spark's GPU goes from about 40 °C to 65 to 75 °C without throttling. Spark available memory flat after load (no leak).
- Requests without the key, or with a wrong one, are refused with 401.

**Measured** (07:38 to 09:08). Logs: `a1-run.log`, `a1-c1.jsonl`, `a1-c2.jsonl`, `a1-c4.jsonl` (Halo, `halo-tuning`); `a1-server.log`, `a1-telem.log` (Spark, `~/halo-tuning`).

| Concurrent requests | Requests | Errors | Generation per request, tok/s (min to max) | Aggregate, tok/s | TTFT p50 / p95 / max, ms | First 10 min vs last 10 min |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 262 | 0 | 59.2 (57.2 to 60.7) | 58.1 | 144 / 156 / 161 | 59.2 → 59.0 |
| 2 | 394 | 0 | 44.9 (42.7 to 52.0) | 87.4 | 256 / 300 / 322 | 45.1 → 44.9 |
| 4 | 676 | 0 | 38.6 (35.1 to 39.8) | 150.0 | 352 / 375 / 395 | 37.7 → 39.2 |

- **Spark GPU temperature:** 40 °C before load, 63 °C within 10 minutes, peak 65 °C, 64 °C at the end. SM clock held at about 2,500 MHz, and no throttle reasons were active. Power during decode was 37 to 43 W.
- **Spark available memory:** 78.9 GB before load, 40.9 GB with the model loaded, 39.0 GB at the end. That's a slow 1.9 GB decline over 85 minutes, steady rather than stepwise. The resident app's processes were also running on the Spark, so this is not attributed to the test server.
- **API key:** with no key or a wrong key, `/v1/chat/completions` and `/v1/models` both returned 401 `Invalid API Key`, and the correct key returned 200. Unexpectedly, `/health` returned 200 without a key, which leaks only whether a server is up.
- **No stalls.** The slowest single request took 11.6 s (400 tokens at concurrency 4).

**Against the prediction.** Concurrency 1 and 4 landed as predicted. Concurrency 2 did not: 44.9 tok/s per request and 87.4 aggregate, against a prediction of 53 and 105. The 45-second smoke test that shaped that prediction was misleading. Its two workers were offset, so they rarely decoded in the same batch. In the long run they mostly decoded together, and only occasional unbatched requests reached 52 tok/s. Temperature and memory matched the prediction, apart from the 1.9 GB decline above.

**Reading.** One Spark server delivers 58 tok/s to one client and 150 tok/s across four, with no errors and no thermal slowdown over 30 minutes at each level. Each extra concurrent request costs per-request speed: about 24% at 2 and 35% at 4. Time to first token stays under 0.4 s throughout.

## A2. `llama-server --rpc` under real load

**Setup.** Head: `llama-server.exe` b12477 Vulkan (`054a1babf`) on the Halo, bound to 127.0.0.1:8098, with the model file on the Halo. Worker: `ggml-rpc-server` b12477 CUDA (`054a1babf`, RPC protocol v10.0.0) on the Spark, bound to 10.10.10.2:50052, with `-c` and a warm 37 GB cache.

```
# Spark
LD_LIBRARY_PATH=. ./ggml-rpc-server --host 10.10.10.2 --port 50052 -c
# Halo, pass 1: everything on the Spark
llama-server.exe -m Qwen3.6-35B-A3B-Q8_0-mtp.gguf -ngl 99 --rpc 10.10.10.2:50052 --device RPC0 `
  --host 127.0.0.1 --port 8098 --ctx-size 32768 -np 4 --flash-attn on
# Halo, pass 2: split (llama.cpp chooses), same flags without --device
```

Same load as A1: `loadgen.py`, 30 minutes each at 1, 2 and 4 concurrent requests. MTP is not enabled, so the file's MTP heads are unused.

**Prediction.**
- Pass 1, all on the Spark: about 17% below A1 at concurrency 1, as in the guide's benchmark (RPC 51.1 against native 61.7), so about 49 tok/s. Batching should spread RPC's fixed per-step cost, so the loss shrinks at higher concurrency: about 38 per request at 2 (76 aggregate) and 33 at 4 (130). TTFT 200 to 300 ms.
- Pass 2, split: about 47 tok/s at 1, 36 per request at 2 (72 aggregate), 30 at 4 (120).
- Both passes: no errors, disconnects or stalls. Halo RAM steady, since the weights are mmapped. Load in about 90 s with the cache warm.

**Measured.** Pass 1 ran 09:15 to 10:45 and pass 2 10:47 to 12:17. Logs on the Halo, in `halo-tuning`: `a2p1-run.log`, `a2p2-run.log`, `a2p{1,2}-c{1,2,4}.jsonl`, `a2p1-server.log`, `a2p2-server.log`, `a2p2-server.guard.log`, `a2-halo-telem.log`. On the Spark: `a2-worker.log`, `a2-telem.log`.

| Layout | Concurrent | Requests | Errors | Per request, tok/s (min to max) | Aggregate | TTFT p50 / p95 / max, ms | First 10 min → last 10 min |
| --- | --- | --- | --- | --- | --- | --- | --- |
| All on Spark via RPC | 1 | 225 | 0 | 51.3 (48.0 to 53.3) | 49.8 | 244 / 257 / 450 | 52.4 → 49.2 |
| All on Spark via RPC | 2 | 316 | 0 | 36.2 (35.4 to 43.9) | 69.9 | 420 / 515 / 579 | 36.5 → 36.0 |
| All on Spark via RPC | 4 | 524 | 0 | 30.1 (29.0 to 30.9) | 115.8 | 519 / 766 / 867 | 30.0 → 30.2 |
| Split | 1 | 211 | 0 | 47.9 (46.3 to 50.7) | 46.9 | 204 / 218 / 278 | 49.2 → 47.2 |
| Split | 2 | 318 | 0 | 36.2 (35.2 to 41.1) | 70.3 | 361 / 397 / 1,474 | 37.2 → 35.7 |
| Split | 4 | 488 | 0 | 28.0 (25.6 to 31.4) | 107.8 | 546 / 694 / 788 | 28.2 → 28.2 |

Against the Spark's own server (A1), RPC lost 13% at one request (59.2 to 51.3), 20% of aggregate at two (87.4 to 69.9) and 23% at four (150.0 to 115.8).

- **No errors, stalls or disconnects** in 2,082 requests over 3 hours (2,208 counting the CPU check below, which also had none). The worker's only `recv failed` lines are the four times I stopped a head server. On the Halo adapter, received and sent errors and discards were 0 for the whole session. On the Spark NIC, `rx_mac_missed` rose by 3 and `rx_dropped` by 0 during the last 24 minutes of split load.
- **Load times** with `--load-mode none` and a warm worker cache: 89 s with everything on the Spark, 45 s for the split, and 72 s for a later reload of the all-on-Spark layout.
- **How the split divided the model:** about 20 GB on each machine. The Halo's GPU memory went from 36.4 to 56.2 GiB, and the Spark's available memory from 39 to 58.8 GB.
- **Spark GPU:** 59 to 65 °C, clocks steady at about 2,500 MHz.

**Incident: the default memory-mapped load starved the Halo of RAM.** The first pass-1 head used the default load mode (mmap). Even with `--device RPC0` putting every layer on the Spark, Windows kept about 24 GiB of the mapped file in the head's working set (24.0 GiB working set, 0.7 GiB private). Available RAM on the Halo fell from 21.5 to 0.1 GiB between 09:10:12 and 09:11:16, and stayed at 0.1 to 0.2 GiB until I stopped it at 09:12:30. Windows trimmed the resident app's four processes to almost nothing. They survived (commit charge was 54 of 128 GiB), but that was luck, not margin. Restarted with `--load-mode none` (b12477 has no `--no-mmap`), the head held 0.6 GiB of working set, available RAM never dropped below 22.9 GiB, and the load took the same 89 s. Every later load ran through `guarded-start.ps1` (`scripts/guarded-start.ps1`), which forces `--load-mode none`, refuses to start below 8 GiB available and kills the process below 4 GiB.

**The split head uses more system RAM at higher concurrency.** During split concurrency 4, available RAM fell from about 22.5 to 14.1 GiB over 8 minutes, then held at 14.1 to 14.8 GiB until the server stopped, when it returned to 23.6 GiB. That's about 8 GiB on a plateau, not a leak. It was not seen with everything on the Spark.

**The "drift" was CPU activity on the Halo, not heat.** At one request, pass 1 ran at 52 tok/s until 09:34:50, then 49 to 50 from 09:34:58 onward. Over the same run the Spark was cooler than in A1 (61 to 63 °C against 65 °C) at the same clocks, so heat doesn't explain it. A test suite (pytest) from the resident app's development ran on the Halo CPU from about 09:14 to 09:34:32. The split pass did the same thing: 49.6 to 50.3 tok/s during a full pytest run (10:51:38 to 10:55:08), then 47.1 to 47.3 once the CPU went idle. A controlled check with everything on the Spark at one request (12:19 to 12:37):

| Segment | Halo CPU | Requests | tok/s per request |
| --- | --- | --- | --- |
| 1, 5 min | idle | 37 | 50.5 |
| 2, 5 min | one busy thread at below-normal priority | 38 | 52.0 |
| 3, 7 min | idle, with a 12-second burst at 12:32:02 to 12:32:14 (single-thread SQLite scans plus 15 embedding calls of about 10 ms each) | 51 | 49.8 overall, 52.5 and 53.2 during the burst, back to 49 to 50 within about 20 s |

So activity on the Halo CPU speeds up the RPC head by about 5 to 7%, and an idle CPU gives the baseline. The likely mechanism is CPU power states: the head makes one round trip per token, and waking cores adds latency to each. That isn't proven here. The Windows power plan was already High performance. One busy thread is a light load, so segments 1 and 2 overlap minute by minute (49.5 to 53.0). The burst and the two pytest windows are the clearer evidence.

**Slow starts are warm-up.** The two slowest starts of all A2 runs (1,357 and 1,474 ms) were the first two requests of split concurrency 2 at 11:17:10, with prompt speeds of 34 to 36 tok/s against about 200 normally. Every other request in that run started in under 443 ms. The first request of each RPC run is the slowest or nearly so (450 ms in pass 1 at concurrency 1, 753 ms in pass 1 at concurrency 4), while A1 without RPC shows no such spike. At 11:17:10 the Spark's telemetry showed no dip and the adapters no errors, and the resident app was idle. One later start of 867 ms (pass 1 at concurrency 4) isn't explained by warm-up.

**Against the prediction.**
- Correct: no errors, stalls or disconnects. At one request, pass 1 (51.3 measured against about 49 predicted) and split (47.9 against 47). Split at two requests (36.2 and 70.3 against 36 and 72). Load time.
- Wrong: the RPC loss does not shrink as concurrency rises, it grows (13%, 20%, 23% of aggregate), so pass 1 at four requests came in at 115.8 against 130 and split at four at 107.8 against 120. Halo RAM was not "steady because the weights are mmapped": mmap was the problem.
- Not predicted: the CPU-activity effect, and the split head's 8 GiB of RAM at concurrency 4.

## A3. Reverse layout: Spark as head, Halo as worker

**Setup.** Worker: `ggml-rpc-server.exe` b12477 Vulkan (`054a1babf`) on the Halo, bound to 10.10.10.1:50052, with `-c`. Head: `llama-bench` b12477 CUDA (`054a1babf`) on the Spark, with the 35B Q8_0 file on the Spark's own disk. The command is the guide's results-table command, so the rows can be compared:

```
# Halo
ggml-rpc-server.exe --host 10.10.10.1 --port 50052 -c
# Spark
./llama-bench -m Qwen_Qwen3.6-35B-A3B-Q8_0.gguf -ngl 99 -p 512,2048 -n 128 -r 2                                   # Spark native
./llama-bench -m ... --rpc 10.10.10.1:50052 --device RPC0 -ngl 99 -p 512,2048 -n 128 -r 2                         # all on the Halo
./llama-bench -m ... --rpc 10.10.10.1:50052 -ngl 99 -p 512,2048 -n 128 -r 2                                       # split
```

The Halo's firewall: the direct link is on the Public profile with notify-on-listen on, and no rule names this program. The existing `HaloDirect - allow Spark` rule (any program, any port, from 10.10.10.2) should admit the connection. Any "allow access" dialog was left unanswered, and a snapshot of the 556 firewall rules taken before the run was compared with one taken after.

**Prediction.**
- Spark native: close to the guide's 2,250 / 2,259 / 61.7.
- All on the Halo via RPC: the Halo's native speed less the same RPC cost the forward direction paid (7 to 15% on prompts, 17% on generation). About 1,500 / 1,450 / 46.
- Split: close to the forward split, since the same two GPUs share the work. About 1,800 / 2,500 / 49.
- The first run, while the worker writes its cache, is slower. Report the second.

**Measured** (12:40 to 12:48). Logs: `a3-run.log`, `a3-rerun.log`, `a3-worker.log`, `a3-worker.guard.log` (Halo, `halo-tuning`). The first run with `-c` took 122 s while the worker wrote 34 GB of cache. Figures are tokens per second, with the guide's forward-direction rows for comparison:

| Where the model runs | Prompt, 512 | Prompt, 2,048 | Generation |
| --- | --- | --- | --- |
| Spark native, CUDA, no RPC (re-runs) | 2,277 ± 18 / 2,273 ± 19 / 2,239 ± 35 | 2,223 ± 5 / 2,246 ± 0 / 2,232 ± 9 | 61.4 ± 0.1 / 61.4 ± 0.0 / 62.4 ± 0.1 |
| **All on the Halo, Spark as head** | 1,601 ± 5 / 1,595 ± 0 | 1,562 ± 4 / 1,562 ± 2 | **40.0 ± 0.1 / 40.0 ± 0.1** |
| **Split, Spark as head** | 1,754 ± 0 / 1,710 ± 15 | 2,061 ± 3 / 2,030 ± 1 | **45.2 ± 0.3 / 45.0 ± 0.2** |
| Guide: Halo only, Vulkan, no RPC | 1,689 ± 7 | 1,635 ± 16 | 55.2 ± 0.0 |
| Guide: all on the Spark, Halo as head | 1,922 ± 71 | 2,111 ± 29 | 51.1 ± 0.6 |
| Guide: split, Halo as head | 1,728 ± 47 | 2,582 ± 46 | 48.7 ± 0.1 |

- **The reverse layout is the slower way round.** With everything on the Halo, RPC cost 5% on prompts and 27% on generation against the Halo's native Vulkan figure. The forward direction cost 7 to 15% and 17% against the Spark's native figure. Split with the Spark as head generated 7% slower than split with the Halo as head (45.1 against 48.7) and processed 2,048-token prompts 21% slower (2,045 against 2,582).
- **One transient.** The first Spark-native run at 12:44:48, directly after the split run, generated at 50.2 ± 0.3 (prompts 2,226 and 2,189). Two immediate re-runs gave 61.4, and a third after a repeat of the split run gave 62.4. Nothing else was using the Spark GPU beyond the resident app's idle processes, the load average was 0.5, and no throttle reasons were active. Unexplained. The table uses the re-runs.
- **Firewall.** The Spark reached 10.10.10.1:50052 through the existing `HaloDirect - allow Spark` rule. Windows still raised its "allow access" dialog when the worker first listened: at 12:39:50 it added two `Query User` rules for `ggml-rpc-server.exe`, and at 12:40:37 someone at the Halo answered Allow, which made them inbound Allow, TCP and UDP, Private and Public, from any address. They were not needed and widen exposure to the LAN. Removing them needs an administrator; they were removed afterwards (see the end of this file).
- **Halo RAM** stayed at 21.4 GiB available or more while the worker ran. With `-c`, the worker's default cache folder is `%LOCALAPPDATA%\llama.cpp\rpc`. Here it was moved into `halo-tuning` with `LLAMA_CACHE`.

**Against the prediction.** Spark native matched once re-run. Everything on the Halo: prompts were better than predicted (1,600 / 1,562 against 1,500 / 1,450) and generation worse (40.0 against 46). Split: prompts at 512 matched (1,730 against 1,800), the 2,048 figure was lower (2,045 against 2,500), and generation was lower (45.1 against 49). Not predicted: the dialog, despite an allow rule already covering the traffic.

## A4. ROCm on the Halo as RPC head

**Setup.** Head: Lemonade's ROCm build b1381 of llama.cpp on the Halo. It reports build 12548, commit `f8caa5ea3`, a different commit from the Spark's b12477 worker. A matching worker was built on the Spark from upstream `f8caa5ea3` in a new worktree at `~/halo-tuning/llama.cpp-f8caa5ea3`, with the same CMake options as the b12477 build (CUDA, RPC, sm 121, Release, shared libraries). Both commits use RPC protocol 10.0.0. Every Halo load ran through `guarded-start.ps1` with `-lm none`. The guide's command, at 512 and 2,048 prompt tokens:

```
# Spark (f8caa5ea3 build)
LD_LIBRARY_PATH=. ./ggml-rpc-server --host 10.10.10.2 --port 50052 -c
# Halo (ROCm b1381)
llama-bench.exe -m Qwen3.6-35B-A3B-Q8_0-mtp.gguf -ngl 99 -p 512,2048 -n 128 -r 2 -lm none                                    # Halo only, ROCm
llama-bench.exe -m ... --rpc 10.10.10.2:50052 --device RPC0 -ngl 99 -p 512,2048 -n 128 -r 2 -lm none                         # all on the Spark
llama-bench.exe -m ... --rpc 10.10.10.2:50052 -ngl 99 -p 512,2048 -n 128 -r 2 -lm none                                       # split
```

Caveat: Lemonade's build may carry patches on top of `f8caa5ea3`. The version string matches the upstream commit, and the RPC protocol versions match, but the source of Lemonade's build was not compared.

**Prediction.**
- Halo only, ROCm: close to the guide's Tuning table (1,550 at 2,048 and 51.1 generating), so about 1,600 / 1,550 / 51.
- All on the Spark: the head's backend barely matters when every layer is remote, so about the same as with Vulkan: about 1,900 / 2,100 / 51.
- Split: the Halo's half runs on ROCm, which is 5 to 10% slower than Vulkan here, so slightly below the Vulkan split: about 1,650 / 2,450 / 47. Published Halo-to-Halo cluster tests favour ROCm on long prompts, so the 2,048 figure is the least certain.

**Measured** (12:55 to 13:04). Logs: `a4-run.log`, `a4v-run.log`, `a4-*.out.log`, `a4-*.guard.log`, `a4v-*` (Halo, `halo-tuning`); `a4-build.log`, `a4-worker.log`, `a4v-worker.log`, `a4-telem.log` (Spark). The worker build took 3.5 minutes once `CMAKE_CUDA_COMPILER` was passed explicitly: in a non-interactive SSH session `nvcc` isn't on the PATH, and the first configure failed. To separate the head's backend from day-to-day variation, the Vulkan rows were re-run in the same session, minutes later, against the b12477 worker. Both ROCm and Vulkan used `-lm none`. Halo available RAM stayed at 21.5 GiB or more in all eight runs. The Spark's GPU peaked at 48 °C.

| Where the model runs | Head backend, commit | Prompt, 512 | Prompt, 2,048 | Generation |
| --- | --- | --- | --- | --- |
| Halo only | ROCm, `f8caa5ea3` | 1,562 ± 15 | 1,552 ± 8 | 50.2 ± 0.1 |
| Halo only | Vulkan, `054a1babf` | 1,652 ± 1 | 1,615 ± 26 | 55.3 ± 0.1 |
| All on the Spark | ROCm, `f8caa5ea3` | 1,981 ± 67 | 2,010 ± 62 | 53.1 ± 0.1 |
| All on the Spark | Vulkan, `054a1babf` | 2,126 ± 28 | 2,076 ± 22 | 53.2 ± 0.2 |
| Split | ROCm, `f8caa5ea3` | 1,680 ± 19 | 2,409 ± 30 | 47.1 ± 0.2 |
| Split | Vulkan, `054a1babf` | 1,739 ± 29 | 2,546 ± 39 | 50.3 ± 0.1 |

- **ROCm does not overtake Vulkan as the RPC head.** With everything on the Spark the two tie on generation (53.1 against 53.2), which makes sense because the head does almost no compute, and ROCm is 7% and 3% slower on prompts. Split, ROCm is 3%, 5% and 6% slower. The long-prompt advantage reported for ROCm in Halo-to-Halo clusters does not show up in this pairing.
- **Today's Vulkan RPC rows beat the guide's.** All on the Spark: 2,126 / 2,076 / 53.2 against the guide's 1,922 / 2,111 / 51.1. Split: 2,546 and 50.3 against 2,582 and 48.7. The differences from 2026-11-20 are `-lm none`, an idle resident app with no other GPU load, and the CPU-activity effect from A2. These runs don't separate them.

**Against the prediction.** Halo-only ROCm (1,562 / 1,552 / 50.2 against about 1,600 / 1,550 / 51) and the ROCm split (1,680 / 2,409 / 47.1 against about 1,650 / 2,450 / 47) both matched. With everything on the Spark, the ROCm head matched on prompts (1,981 / 2,010 against about 1,900 / 2,100) and beat the prediction on generation (53.1 against 51), but the same-session Vulkan reference shows that's not a ROCm gain.

## Phase B: prepared, not run (needs someone at the machines)

### B1. A model too big for either box

**Proposal: Qwen3.5-397B-A17B, Unsloth `UD-Q3_K_S`.** Five files totalling 164.3 GB (153.0 GiB), per the Hugging Face file listing. Neither machine can hold it alone: with the resident app stopped, the Halo's GPU has about 106 GiB free and the Spark about 115 GiB. Together they have about 220 GiB, which leaves about 65 GiB for KV cache and compute buffers. It uses the `qwen35moe` architecture, the same as the 35B that b12477 already runs. Fallback: Qwen3-235B-A22B-Instruct-2507 `Q4_K_M`, 142.2 GB (132.4 GiB).

- **Download:** 1 GiB of the second file came in 17.2 s, about 62 MB/s. If that holds, the whole model takes about 45 minutes. The Halo has about 1.2 TB free on C: (1.25 TB, less the 34 GB A3 cache in `halo-tuning\rpc-cache`).
- **Prerequisites, each a decision for whoever runs it:**
  - The resident app's chat model stopped on the Halo.
  - The resident app's three llama-server services stopped on the Spark, which needs root there.
  - Nothing else holding Halo GPU memory.
- **RAM risk:** during A2 the split head used about 8 GiB of extra system RAM at concurrency 4. Run B1 at concurrency 1 first, behind the guard.

```
# Halo: download (resumable), into halo-tuning only
mkdir $env:USERPROFILE\halo-tuning\models\Qwen3.5-397B-A17B-UD-Q3_K_S
cd $env:USERPROFILE\halo-tuning\models\Qwen3.5-397B-A17B-UD-Q3_K_S
1..5 | % { $f = "Qwen3.5-397B-A17B-UD-Q3_K_S-0000$_-of-00005.gguf"; curl.exe -L -C - -o $f "https://huggingface.co/unsloth/Qwen3.5-397B-A17B-GGUF/resolve/main/UD-Q3_K_S/$f" }

# Spark: b12477 worker, cache on
cd ~/llama.cpp-b12477/build-rpc/bin && LD_LIBRARY_PATH=. ./ggml-rpc-server --host 10.10.10.2 --port 50052 -c

# Halo: device list, then the guide's benchmark, behind the guard (-lm none, 8 GiB to start, kill under 4 GiB)
$m = "$env:USERPROFILE\halo-tuning\models\Qwen3.5-397B-A17B-UD-Q3_K_S\Qwen3.5-397B-A17B-UD-Q3_K_S-00001-of-00005.gguf"
$vk = "<folder of your b12477 Vulkan build>"
& $vk\llama-bench.exe --rpc 10.10.10.2:50052 --list-devices
.\guarded-start.ps1 -Exe "$vk\llama-bench.exe" -ArgList '-m',$m,'--rpc','10.10.10.2:50052','-ngl','99','-p','512,2048','-n','128','-r','2','-lm','none' -LogBase .\b1-bench
# then the server, 10 minutes at concurrency 1 with loadgen.py
.\guarded-start.ps1 -Exe "$vk\llama-server.exe" -ArgList '-m',$m,'-ngl','99','--rpc','10.10.10.2:50052','--host','127.0.0.1','--port','8098','--ctx-size','8192','-np','1','--flash-attn','on','-lm','none' -LogBase .\b1-server
```

### B2. Cable pulled mid-session

Runs during an A2-style load, with everything on the Spark at one concurrent request. Someone at the machines pulls the cable for about 30 s, notes the time, then plugs it back in.

```
# Spark: worker as in A2, plus a timestamped link probe
LD_LIBRARY_PATH=. ./ggml-rpc-server --host 10.10.10.2 --port 50052 -c
ping -D -i 0.5 10.10.10.1 > ~/halo-tuning/b2-ping.log
# Halo: head behind the guard, a link probe, and the client with a short timeout
.\guarded-start.ps1 -Exe "$vk\llama-server.exe" -ArgList '-m',"$h\models\Qwen3.6-35B-A3B-Q8_0-mtp.gguf",'-ngl','99','--rpc','10.10.10.2:50052','--device','RPC0','--host','127.0.0.1','--port','8098','--ctx-size','8192','-np','1','--flash-attn','on','-lm','none' -LogBase .\b2-server
ping -t 10.10.10.2 | % { "$(Get-Date -Format o) $_" } > b2-ping.log
python -I loadgen.py --host 127.0.0.1 --port 8098 --concurrency 1 --seconds 600 --timeout 60 --log b2.jsonl --label b2
```

To record:
- the client's errors and their times;
- what the head prints to stderr, and whether it exits or hangs;
- the worker's log lines;
- whether requests succeed again after reconnecting, without restarting either end;
- if not, the steps needed to recover.

### B3. Jumbo frames

Both changes are root or administrator changes. Changing the Halo setting resets the adapter, so the link drops for a few seconds. Make it with nothing running.

```
# Spark (root), temporary until the next link reset or reboot:
sudo ip link set dev enP7s7 mtu 9000
#   undo:
sudo ip link set dev enP7s7 mtu 1500
#   (persistent would be: sudo nmcli con modify halo-direct 802-3-ethernet.mtu 9000 && sudo nmcli con up halo-direct)

# Halo (administrator PowerShell), driver values 1514 / 4088 / 9014 / 16128:
Set-NetAdapterAdvancedProperty -Name HaloDirect -RegistryKeyword '*JumboPacket' -RegistryValue 9014
#   undo:
Set-NetAdapterAdvancedProperty -Name HaloDirect -RegistryKeyword '*JumboPacket' -RegistryValue 1514

# Verify with don't-fragment pings of 8,972 bytes (9,000 less 28 bytes of headers)
ping -M do -s 8972 -c 3 10.10.10.1          # Spark
ping -f -l 8972 -n 3 10.10.10.2             # Halo
```

Current values: the Spark's `enP7s7` (driver r8127) is at MTU 1500, maximum 9194. The Halo's `HaloDirect` has `*JumboPacket` at 1514.

Measuring load time: the worker must run **without** `-c`, or the weights come from the Spark's disk instead of over the cable. Time three loads of the 35B with everything on the Spark, from start to `/health` ok, before and after:

```
# Spark
LD_LIBRARY_PATH=. ./ggml-rpc-server --host 10.10.10.2 --port 50052      # no -c
# Halo, three times each way
.\guarded-start.ps1 -Exe "$vk\llama-server.exe" -ArgList '-m',"$h\models\Qwen3.6-35B-A3B-Q8_0-mtp.gguf",'-ngl','99','--rpc','10.10.10.2:50052','--device','RPC0','--host','127.0.0.1','--port','8098','-lm','none' -LogBase .\b3-load
```

## Still untested, and why

| Item | Why not tonight |
| --- | --- |
| B1, a model too big for either box | Needs the resident app's chat model stopped on the Halo and its services stopped on the Spark (root). Candidate, download time and commands are above. |
| B2, cable pulled mid-session | Needs someone at the cable. Commands are above. |
| B3, jumbo frames | Needs root on the Spark and an administrator adapter change on the Halo. Commands and their undo are above. |
| Whether MTP's different answers are less correct | Covered by a separate test plan. |
| The worker as a boot-time service, and recovery when the link returns | Covered by a separate test plan. |
| Which end causes the 2 to 3 ms delay | Needs a second 10GbE adapter. |
| Whether a fixed CPU power state recovers the 5 to 7% an idle Halo costs the RPC head | Found tonight (A2). Testing it means changing the power plan's minimum processor state, which is a settings change. |
| The 1.9 GB decline in Spark available memory during A1 | The resident app's processes shared the Spark, so it can't be attributed without a run with them stopped. |
| The 50.2 tok/s Spark-native transient in A3 | Didn't recur in three re-runs. |

## What was started and stopped

Everything below was stopped by 13:04:22, and only the resident app's processes were running afterwards on either machine.

- **Spark:**
  - A1 `llama-server` (911962) and `telem.sh` (911963).
  - The A2 b12477 worker and its telemetry.
  - The A4 `f8caa5ea3` worker and its telemetry.
  - The A4 Vulkan-reference b12477 worker.
  - The `a4-build.sh` build, which exited by itself.
- **Halo:**
  - A2 head servers 24848 (the mmap run), 17872 (exited on its own: bad flag), 7024, 22808 and 7008, with their watchdogs.
  - Halo telemetry 15760.
  - A3 workers 6192 and 22440.
  - The busy-thread `spin.py` (22632), which exited by itself.
  - The A4 `llama-bench` runs, which exited by themselves, with their watchdogs.

**Left in place for Phase B:**
- On the Halo:
  - A 34 GB worker cache in `halo-tuning\rpc-cache`. It only saves reload time; delete it once B1 is done.
  - The new SSH key and config in `~\.ssh` on the Halo.
- On the Spark:
  - The worktree and build at `~/halo-tuning/llama.cpp-f8caa5ea3`.

**Removed afterwards:**
- The two Windows Firewall rules that the dialog created at 12:40:37 (`TCP Query User{AF168285-…}` and `UDP Query User{E2AC7259-…}`, for the b12477 `ggml-rpc-server.exe`). An administrator removed them, and the rule count went back to the 556 in the snapshot taken before A3.
- The test API key file, on both machines. Before deleting it I searched both machines and the guide repo: the key wasn't in any log or other file.
