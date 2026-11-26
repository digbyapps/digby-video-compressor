# Speed, progress and estimates (Nov 2026)

Measured with `DIGBY_STAGE_LOG=1 digby compress …` (one line per stage with its wall time).
The machine's load average was 15–30 throughout because other work was running, so the
absolute times are noisy: the same stage varied up to 2× between runs. The conclusions rest
on where the time goes, which was the same in every run.

## Why it looked stuck near 100 %

Progress weights were in "seconds of video encoded", and the checks after the encode were
under-weighted or left out:

* The media-engine path ("Fastest") measures VMAF and may re-encode once (`correctAfterEncode`).
  That measurement had **weight 0** whenever "Check quality" was off, and only 0.2 × duration
  otherwise. Result: **83 % after a 7 s encode, then 99 % for about 60 s** (12 s 4K clip).
* The final text check (OCR plus a near-lossless reference encode) had no weight at all.
* VMAF's own progress was wrong: with `setpts=N` its timestamps are frame numbers in ms, so the
  stage bar sat near 0 and then jumped to the end.

Fixes:

* Every stage is now weighted in estimated **wall-clock seconds** (`StageCost`, from the
  benchmark encoder and VMAF speeds). The checks get their real share of the bar.
* New stage "Checking text is readable". "Measuring quality" is renamed "Checking quality".
  Both checks show their own percentage in the title ("Checking quality… 40%").
* VMAF progress is computed from the subsampled frame count.

| Run (12 s 4K, Fastest) | Bar when the encode ends | Then |
|---|---:|---|
| Before | 82.6 % | 99.2 % for ~55 s |
| After | 9.1 % | moves through "Checking quality… n %" and "Fine-tuning" to 99 % |

## Timings, before → after (same outputs: identical size and VMAF)

| Clip | Mode | Before | After | Note |
|---|---|---:|---:|---|
| 12 s 4K HEVC (upscaled) | default (x265) | 1,410 s | 1,000 s / 1,990 s | two runs under different load; the search was faster (1 fewer probe), the final-preset confirm and encode dominate |
| 12 s 4K | Fastest | 70 s | 68 s | — |
| 12 s 1080p h264 | default | 702 s | 777 s | search 353 → 253 s; encode stage slower under load |
| 12 s 1080p | Fastest | 39 s | 39 s | — |
| 20 s lecture ProRes | default | 173 s | 174 s | — |
| 20 s lecture | Fastest | 37 s | 38 s | — |

Honest summary: **jobs aren't materially faster yet.** The quality search now runs at most 4
probes instead of 5 (it converged within 4 on every clip tested). VMAF subsampling now drops
frames before scaling, which made no difference (the cost is decoding, not scaling). The fix
here is that progress is now truthful. I tried a bigger speed lever and reverted it (below).

### Tried and reverted: searching 4K on 1080p samples

The search phase on 4K went from 782 s to 131 s. But on the upscaled 4K clip, the setting found
at 1080p didn't carry over. I tried three ways of checking it at full size (full-preset
confirm, proxy-preset confirm, confirm on a 3 s slice). Each one either cost the time back
(4K trials at the slow preset take minutes) or produced a file larger than the original. The
light version used for estimates said 1.3 MB against a real 40 MB. The quality target matters
more than the time, so it was removed. Doing this safely needs a per-content calibration
between 1080p and 4K VMAF, which is follow-up work.

## Estimates

* **Instant (default display):** `SizeEstimator.instantVideoKbps` gives a bitrate from the content analysis
  (bits per pixel by class and complexity, codec and quality factors from
  `Benchmarks/results/m1max_1080p.jsonl`). For delivery-bitrate sources it blends in the
  source's own bitrate (weighted 3:1 towards the source). It takes about 1 ms, so the panel never shows "…" any more.
  It is rough: 10.8 MB vs a real 40 MB on the 4K clip, and 0.6 MB vs 233 MB on a
  noisy clip that tops out at VMAF 92. So it's always shown with a range and a
  plain note that no test encode has run yet.
* **Accuracy menu** in the estimate card (saved in preferences):
  * **Quick** (default): the instant figure, then one light sample search per video in the background. Other
    settings are scaled from that search.
  * **Accurate**: a light sample search at exactly the chosen settings, redone 0.7 s after they
    change.
  * **Exact**: the full search the compression runs. It's cached, so compressing afterwards
    skips the search.
* Every figure is labelled "Likely A–B" with what it rests on. The range half-widths are ×3 (model), ×1.6
  (scaled), ×1.4 (sampled) and ×1.1 (exact). The light sample search itself was found to be
  well off on hard clips (70.9 MB estimated vs 233 MB actual on the noisy 1080p clip), so
  the ranges are deliberately wide.
* A refinement in progress shows "refining…" and keeps the last figure on screen. Nothing waits on it.

## Follow-ups

* The light sample search (3 probes, 8 s) under-predicts hard content badly. Give it a better first guess
  or a 4th probe when it ends far from the target.
* Safe reduced-resolution search for 4K (see above).
* Pre-existing: `compress` passes an item that already has its edits applied to `cachedDecision`, which applies
  the edits again. Check that trims aren't applied twice.
