# Gold-standard audit: what Digby Video Compressor must become

*Audit date: 15 November 2026. Covers the 1.1.0 codebase, the bundled engine, and the competitive landscape as of November 2026.*

## How to read this

Every claim is tagged with where it comes from:

| Tag | Meaning |
|---|---|
| **[Test]** | I ran it on this Mac (M1 Max) during the audit. Raw commands and numbers are in the appendix. |
| **[Code]** | Read directly from the source, with file references. |
| **[Report]** | From the project's own `Tests/integration/REPORT.md` or `Docs/ENCODING.md`. |
| **[Source]** | From a competitor's own site, release notes or documentation (linked at the end). |
| **[3rd-party]** | From reviews, reseller or comparison sites. Treat as indicative, not verified. |
| **[Rec]** | My recommendation. Not a fact. |

Timing caveat: during my tests the machine's load average was 9–30 because of other work. The speed numbers are indicative, not benchmark-grade. They are large enough that the conclusions do not depend on the exact figures.

---

## 0. Executive summary

**The engine is better than any competitor's at the thing it set out to do. The product around it is not yet a gold-standard app.**

What Digby already does that no competitor I found does:

* It measures quality instead of guessing. The quality levels are VMAF targets, searched on samples of the actual video. **[Code]**
* Its target-size mode is honest. It encodes the audio first, uses two passes, checks the file and re-encodes if it is over. It says so when the target is more than the video needs. It suggests a lower resolution when that measurably looks better. **[Code][Report]** HandBrake no longer has a target-size mode at all **[Source]**, and the consumer apps that do have one do not say whether they verify the result.
* It has a text-legibility guard: on-device OCR checks that slides and captions still read correctly after compression. I found nothing like this anywhere else.
* It is safe with originals: partial files are written and renamed atomically, the replace mode uses the Trash, and Restore works.
* It knows whether the output will preview in Finder on this Mac, and it labels results accordingly.

The six biggest problems, in order:

1. **It is far too slow for an ordinary user.** **[Test]** With the default settings, 12 seconds of 4K took **556 s** to compress. "Hardware · Fastest" took **210 s**, but the hardware encode itself takes **4 s** when run on its own. The time goes on the sample search and the full-video VMAF measurement, not on the encoder. In the project's own report a 24-second clip took 1,417 s **[Report]**. A first-time user will assume the app has hung. Permute, Compresto and the macOS Finder action finish this kind of job in seconds.
2. **It silently drops content that users care about.** **[Test]** All subtitle tracks are removed, although the README says text subtitles are kept. Every audio track after the first is removed; the `keepAllAudioTracks` setting exists but nothing reads it. The creation date and Apple's location, make and model tags are lost, so an iPhone video re-imported into Photos shows today's date. HandBrake 1.10 fixed exactly this in August 2025 **[Source]**.
3. **The first screen asks too much of a novice.** About 25 decisions are visible before **Compress**: resolution (7), size mode, 5 levels or 5 sizes plus a custom value, format (4), text guard, audio, content type, effort (3), skip threshold, an estimate panel, an engine summary line and Advanced. "Preview Studio…" appears twice **[Test: render]**. The UI is organised around encoder concepts. It should be organised around what the user is trying to do.
4. **Some of what it reports is technically correct but misleading.** **[Code]** The quality rating is measured at the output resolution, so a 4K video shrunk to 480p can be rated "Excellent". The rating never reflects the lost resolution. The text guard, when switched on and no text is found, still raises the quality target and shows a green "Text kept readable" chip. In the integration suite, screen recordings were delivered at 83–86 % legibility while the guard's own threshold is 97 %, and the report still marks them as passed **[Report]**.
5. **The quality tuning may be optimising the metric rather than the picture.** **[Code][Source]** SVT-AV1 runs with `tune=1` (PSNR), chosen because it scored ~6 % better on VMAF. Since SVT-AV1 3.0–4.0, the default visual-quality tune has absorbed the psychovisual work from SVT-AV1-PSY (variance boost, AC bias), which preserves texture and grain. VMAF is known to under-reward grain retention and to miss banding **[Source]**. Choosing a tune by VMAF therefore biases the output towards smooth and plastic. This needs a blind visual test before anything else is tuned.
6. **It is not shippable to the public as a trusted product yet.** It is not notarised (first launch needs right-click → Open), has no auto-update, is ad-hoc signed and requires macOS 26 on Apple Silicon. It bundles GPL x264/x265, which constrains any commercial or App Store plan. The product name is unsettled: Digby is on `main`, and the working tree renames everything to Digby.

**Overall:** the engine is around 85 % of the way to gold standard. As a product the app is around 50–55 %. The good news is that none of the gaps needs an engine rewrite. The architecture (pure planner, encoder back-ends as argument mappers, FFmpeg as a subprocess, an optimiser built from trial primitives) is the right one and should be kept.

---

## A. Competitive feature matrix

### A1. Who the competitors actually are

| Product | Who it serves | Price (Nov 2026) | Platform |
|---|---|---|---|
| **HandBrake 1.11.2** | Enthusiasts, rippers, power users | Free, GPL | Mac, Windows, Linux **[Source]** |
| **Apple Compressor 5.3** | Final Cut professionals, Apple-ecosystem delivery | $49.99 one-off (US) **[Source]** | Mac |
| **Permute 4.1** | Prosumers who want "drop and convert" | $14.99; Setapp **[Source]** | macOS 26+, Apple Silicon only (same as Digby) **[Source]** |
| **Shutter Encoder** | Editors, broadcast, archivists | Free, donations **[Source]** | Mac, Windows, Linux |
| **Compresto** (formerly CompressX) | Consumers, creators | Perpetual licence, 1 year of updates; Setapp **[Source][3rd-party]** | macOS 13+ |
| **Smol** | Consumers who compress many file types | $29 one-off **[3rd-party]** | macOS 13+ |
| **VideoProc Converter AI** | Consumers | ~$25.95/yr or ~$39.95 lifetime **[3rd-party]** | Mac, Windows |
| **Movavi Video Converter** | Consumers | Subscription; prices vary by source **[3rd-party]** | Mac, Windows |
| **Adobe Media Encoder 2026** | Premiere/After Effects users | Creative Cloud **[3rd-party]** | Mac, Windows |
| **Finder "Encode Selected Video Files"** | Everyone with a Mac | Free, built in | macOS |

The two real threats are **Permute 4** (cheap, polished, same platform floor, now has drop zones, trim and crop, a file-size limit with hardware encoding, Shortcuts and track editing) and **Compresto** (hardware-fast, watch folders, a floating drop zone, Raycast, and images/PDF/GIF too). HandBrake sets the bar for fidelity and breadth. Neither of the threats competes on measured quality.

### A2. Feature matrix

✅ = has it · ◐ = partial or limited · ❌ = no · ? = could not verify

| Capability | Digby 1.1 | HandBrake | Compressor | Permute 4 | Shutter Enc. | Compresto |
|---|---|---|---|---|---|---|
| Target file size | ✅ verified ≤ target **[Code]** | ❌ removed **[Source]** | ◐ data-rate only | ✅ "file size limit" **[Source]** | ? | ❌ not mentioned **[Source]** |
| Quality presets in plain language | ✅ 5 levels, VMAF-backed | ◐ RF number | ◐ | ✅ | ◐ | ✅ |
| Measured output quality (VMAF) | ✅ every file | ❌ | ❌ | ❌ | ◐ analysis tool **[Source]** | ❌ |
| Content-aware tuning | ✅ | ◐ tune presets | ❌ | ❌ | ❌ | ❌ |
| Text/slide legibility guard | ✅ unique | ❌ | ❌ | ❌ | ❌ | ❌ |
| AV1 encode | ✅ SVT-AV1 | ✅ SVT-AV1 4.1 **[Source]** | ? | ✅ **[Source]** | ✅ | ? |
| HEVC / H.264 (software and hardware) | ✅ | ✅ | ✅ (hardware) | ✅ | ✅ | ✅ (hardware) |
| ProRes / DNxHR output | ❌ | ✅ 1.11 **[Source]** | ✅ | ✅ (hardware ProRes) | ✅ | ❌ |
| Output containers | MP4 only **[Code]** | MP4, MKV, WebM, MOV (1.11) | many | many | many | MP4, MOV |
| Keeps all audio tracks | ❌ **[Test]** | ✅ | ✅ | ✅ + reorder **[Source]** | ✅ | ? |
| Keeps subtitles | ❌ **[Test]** | ✅ passthrough or burn-in | ✅ | ✅ + add by drop **[Source]** | ✅ | ? |
| Keeps chapters | ✅ **[Test]** | ✅ | ✅ | ✅ | ✅ | ? |
| Keeps creation date and location | ❌ **[Test]** | ✅ since 1.10 **[Source]** | ✅ (AVFoundation) | ✅ + metadata editor | ? | ? |
| HDR10 static metadata | ✅ **[Test]** | ✅ | ✅ | ? | ✅ | ? |
| Dolby Vision / HDR10+ | ❌ dropped **[Code]** | ✅ passthrough | ✅ | ? | ? | ? |
| HDR → SDR tone mapping | ❌ | ✅ | ✅ | ? | ✅ | ? |
| Trim | ❌ | ◐ by time or chapter | ✅ | ✅ rebuilt **[Source]** | ✅ | ? |
| Crop / auto-crop | ❌ | ✅ auto | ✅ | ✅ | ✅ | ? |
| Rotate / flip | ❌ | ✅ | ✅ | ✅ | ✅ | ? |
| Deinterlace | ✅ automatic | ✅ | ✅ | ? | ✅ | ? |
| Denoise / sharpen | ❌ (grain synthesis only) | ✅ | ◐ | ❌ | ✅ | ❌ |
| Audio loudness normalisation | ❌ | ❌ (gain only) | ✅ | ◐ volume | ✅ EBU R128 **[Source]** | ❌ |
| Batch / folder import | ✅ recursive | ✅ | ✅ | ✅ | ✅ | ✅ |
| Watch folders | ❌ | ❌ | ✅ droplets | ◐ via Shortcuts/Folder Actions **[3rd-party]** | ❌ | ✅ **[Source]** |
| Drop zone / floating target | ❌ | ❌ | ✅ droplets | ✅ **[Source]** | ❌ | ✅ |
| Shortcuts / App Intents | ❌ | ❌ | ◐ | ✅ **[3rd-party]** | ❌ | ? (Raycast ✅) |
| Pause and resume a job | ❌ (cancel, or resume after quit) | ✅ | ✅ | ? | ? | ? |
| Parallel jobs | ❌ one at a time | ◐ | ✅ distributed | ? | ? | ✅ "parallel" **[Source]** |
| Before/after compare | ✅ split, flip, zoom, worst moments | ◐ preview | ◐ | ❌ | ❌ | ❌ |
| Several outputs per source | ✅ Versions | ◐ queue duplicates | ✅ | ◐ | ◐ | ❌ |
| Replace originals safely, with undo | ✅ Trash + Restore | ❌ | ❌ | ◐ trash/move/delete **[Source]** | ❌ | ? |
| Skip files that wouldn't shrink | ✅ | ❌ | ❌ | ? | ❌ | ? |
| Command line | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Notarised, auto-updating | ❌ | ✅ | ✅ (App Store) | ✅ | ✅ | ✅ |
| Low-power / background mode | ❌ | ❌ | ❌ | ✅ **[Source]** | ❌ | ? |

### A3. Strengths, weaknesses and how to beat each one

| Competitor | Real strength | Real weakness | How Digby wins |
|---|---|---|---|
| **HandBrake** | Fidelity (tracks, subtitles, metadata, HDR passthrough), breadth, free, trusted | Jargon ("RF", which way the slider goes) **[3rd-party]**; no target size; no idea what the result looks like | Match its fidelity and keep the measured quality and honest sizes. Become "HandBrake's results without HandBrake's homework". |
| **Compressor** | Apple-native, droplets, distributed encoding, immersive/spatial video **[Source]** | Professional mental model, no quality feedback, weak efficiency per byte (hardware) | Don't chase immersive video. Win on quality per MB and on explanation. |
| **Permute 4** | Price, polish, trim/crop, drop zones, track editing, Shortcuts, low-power mode | Nothing indicates it measures quality or verifies the size limit | Be visibly smarter ("measured", "will fit, guaranteed") while matching its convenience (drop zones, Shortcuts, trim). |
| **Shutter Encoder** | Huge function list, VMAF and loudness tools, free | Dense UI; built for people who already know what they want | Keep pro depth in an inspector, not on the front screen. |
| **Compresto** | Speed (VideoToolbox), watch folders, drop zone, multi-format | Preset-only control; quality claims ("no quality loss") contradicted by its own FAQ **[Source]**; no target size | Be as fast in its default case (hardware path), and honest where Compresto overclaims. |
| **VideoProc / Movavi** | Familiar "converter" UX, AI upscaling | Reviewers report visible quality loss **[3rd-party]**; billing complaints (Movavi) **[3rd-party]** | Trust: no subscription traps, measured quality. |
| **Finder Quick Action** | Zero friction: right-click, done | Few options, reported flakiness **[3rd-party]** | Offer the same zero-friction entry point (Quick Action / Share extension) with Digby's intelligence behind it. |

---

## B. UX/UI benchmark

### B1. What to learn from each

* **Permute and Compresto: "drop it and it's done."** The front door is a drop target and a preset, not a form. Permute's drop zones are presets you drop files onto **[Source]**. Learn: the default path is one gesture. Settings exist, but you go to them; they don't come to you.
* **HandBrake: the preset list as the primary control.** Its "Social 10MB" presets (1.10) name a destination, not a codec **[Source]**. Learn: name presets by where the video is going. Avoid: RF numbers as the main control, and sliders whose direction is ambiguous **[3rd-party]**.
* **Compressor: droplets and the batch inspector.** One setting can be applied to hundreds of files without opening the app. Learn: the inspector pattern (selected job → properties) for advanced settings.
* **Shutter Encoder: function-first organisation.** Avoid this for consumers. It is fine for experts, but it puts the burden of choosing on the user.
* **Apple Photos / iMovie "Share" and AirDrop:** after the work is done, the result goes straight to its destination. No competitor does this well. Learn: the job isn't finished when the file is written, but when it has been sent.

### B2. Digby today, by stage of the job

| Stage | What's good **[Code][Test]** | What's wrong | Fix **[Rec]** |
|---|---|---|---|
| **Empty state** | Clear drop zone, "Choose Videos…", tasteful brand motif | Gives no hint about *what* you can achieve ("fit for email", "save space") | Empty state = 4–6 large goal tiles that also work as drop targets |
| **Import** | Recursive folders, skips own outputs, "Add Anyway" | Analysis (probe, content bursts, OCR) runs before anything else is possible; estimates show "…" for a long time and wait while the queue is busy | Show goal tiles immediately; analyse in the background; never block an estimate on the queue (run estimates at low priority) |
| **Settings** | Every option has an explanation; estimates under each option; "You'll get" line | ~25 visible decisions; codec names on the main screen ("AV1 · Smallest", "HEVC · Previews in Finder"); "Effort" and "Content" are expert concepts; duplicate Preview Studio button; text-guard chip claims "kept readable" when there is no text | Goal → one "smaller ↔ better" control → Compress. Move Format, Effort, Content and Skip into an inspector. One Preview button. |
| **Waiting** | Progress stages with details, ETA, Dock progress, keeps the Mac awake | Very long jobs, and the stage names ("Optimising", "Measuring") don't tell a novice why it takes 40× real time | Fast path by default; show "Testing 3 settings on 20 s of your video (1 of 3)…" with a skip button ("Use best guess now") |
| **Result** | Measured size, saving and quality, legibility, Quick Look note, Play, Show in Finder, Compare | Quality badge ignores resolution loss; no Share, AirDrop, Mail or Messages; no "make it smaller" one-click retry | Add a Share menu and "Smaller / Better" re-run buttons. Rate quality against the *original* viewing size as well as the output size. |
| **Batch** | Report, CSV, saved-space counter, resume after quit, Restore Originals | No reordering, no pause, one job at a time | Reorder by drag, pause/resume, parallel hardware jobs |

### B3. Accessibility audit **[Code]**

The whole app has **six** accessibility modifiers.

* Custom `PillButton`/`OptionPill` controls are the main selection UI. They don't expose a selected state (`.accessibilityAddTraits(.isSelected)`). The estimate under each pill is read as a separate element, so VoiceOver reads "1080p", then "≈ 12 MB" as unrelated items.
* Meaning is carried by colour alone in several places: estimate turns orange when it would be skipped, green "Plays in Quick Look" vs orange "No Quick Look".
* Fixed point sizes (`.system(size: 10.5)`, `12.5`, `13`) are used throughout. Some captions are 10.5 pt on a busy panel; check them against WCAG contrast in both themes.
* `StreaksView` respects Reduce Motion in the drop zone and About window, but the progress animation's motion has not been checked against it.
* No Full Keyboard Access audit: can every pill, menu and the compare view be reached and operated with Tab and the arrow keys?
* No VoiceOver announcement when a job finishes or fails (`AccessibilityNotification.Announcement`).
* Compare view: zoom and flip are pointer-centric. They need keyboard equivalents, announced.

**[Rec]** Treat VoiceOver as a release gate. Run every flow with VoiceOver and Full Keyboard Access before 1.2 ships, and add an `accessibilityLabel` and value to every custom control.

### B4. Language audit

Good: plain-English quality levels, "Left as it is", "Your original file was not changed."

Needs work:

* "VMAF", "two-pass", "x265", "8-bit", "kbps" appear in the always-visible engine summary line (`PlanSummary`). Keep it, but put it in the inspector.
* "Effort: Quick / Smart / Best Possible" describes the engine, not the outcome. Rename it **"How hard to try: Fast · Recommended · Smallest possible"**, with time shown under each.
* "Content: Talking Head / Animation" lumps two unlike things together and is confusing for a webcam lecture. Rename to "Type of video" and use outcome language: "Camera footage", "Slides & screen recordings", "Animation & graphics", "Mixed".
* "AV1 · Smallest" names a codec. Replace the Format row with **"Where will it be played?"**: "Apple devices & Finder (recommended)", "Anywhere, including old devices", "Web & modern players (smallest)". Show the codec as a secondary caption.

---

## C. Compression technology benchmark

### C1. Encoders: what the project's own measurements say **[Report: Docs/ENCODING.md]**

BD-rate against x264 *slow* at equal VMAF (negative = smaller file):

| Encoder | Camera footage | Synthetic (animation, screen) | Speed (park_joy 1080p50) |
|---|---:|---:|---:|
| SVT-AV1 preset 4 | −23 % | −79 % | 21 fps |
| x265 slow | −19 % | −39 % | 8 fps |
| x264 slow | 0 | 0 | 29 fps |
| VideoToolbox HEVC | **+52 %** | **+157 %** | 141 fps |

These numbers are self-consistent and the methodology (lossless masters, frame-paired VMAF, BD-rate over overlapping ranges) is sound. Two caveats:

1. **Every decision was scored with VMAF v0.6.1** (not NEG, no banding term). VMAF is known to miss banding and to under-reward grain retention **[Source]**. Decisions that trade texture for smoothness, such as `tune=1` over `tune=0` and the strength of film-grain synthesis, are exactly the ones VMAF is worst at judging.
2. **The VideoToolbox figure is for an M1 Max.** Apple's later media engines may be better. **[Rec]** Re-run `Benchmarks/speed.py` and `bench.py` on an M3/M4 before hard-coding "hardware is 1.8× bigger" into estimates.

My own spot check **[Test]**: 12 s of 4K landscape at Balanced. x265 slow gave 4.0 MB (VMAF 93.0); VideoToolbox HEVC gave 9.7 MB (VMAF 93.3) — **2.4× larger**, consistent with the study.

### C2. Where efficiency, quality, speed and reliability can improve

| Area | Finding | Recommendation **[Rec]** |
|---|---|---|
| **SVT-AV1 tune** | `tune=1` (PSNR) chosen on VMAF. SVT-AV1 ≥ 3.0 ported the PSY features into the default VQ tune; 4.0 added AC bias "for detail preservation and film grain retention"; 4.2 added a VMAF tune **[Source]** | Run a blind A/B (10+ clips, 5+ viewers, on a good display) of `tune=0` vs `tune=1` at equal size. **Do not** adopt the new VMAF tune: that optimises the score, not the picture. |
| **Quality metric** | VMAF v0.6.1 mean, with a p5 floor | Add **CAMBI** (in libvmaf) as a banding check whenever `bandingRisk` is true. Score with the NEG model as a guard against "enhancement" effects. Keep p5 as the pass criterion, not only the mean. |
| **Sample representativeness** | 4–10 segments of ~2 s, concatenated. Every segment boundary is a scene cut, so each starts with a keyframe **[Code: SampleSet.swift]**. You found this bias yourself in the text guard (frames just after a keyframe flatter the result). | Make segments ≥ 5 s, or prepend 1 s of warm-up and exclude it from scoring. Then log sample-vs-final VMAF and size error for every job, and track it. |
| **Closed loop** | Full-video VMAF is measured, but if it lands below target nothing happens **[Code: CompressionEngine.swift]** | If final p5 is > 2 points under target, offer "Re-encode one step better" (or do it automatically in Recommended mode). |
| **Resolution-blind rating** | The reference is scaled to output size before VMAF **[Code: QualityMeter.swift]**, so downscaling never lowers the score | Report two things: "Compression quality: Excellent" and "Detail: 720p (was 4K)". Or score against the source at a fixed viewing size (e.g. 1080p display). |
| **Speed — measurement cost** | "Fastest" spent ~206 of 210 s outside the encoder **[Test]** | Make full-file VMAF optional by default for hardware/fast paths. Measure at ≤ 1080p with heavier subsampling (every 10th frame is statistically fine for the pooled mean). Run it *concurrently* with the next job's encode. |
| **Speed — search cost** | Up to 5 probes × (encode + VMAF) on 20 s of FFV1 at full output resolution | Do trials at reduced effort (preset +2) and correct with a measured offset; use 2–3 probes with a better first guess (the content analysis already predicts it); cache by content fingerprint across sessions. |
| **Speed — x265 slow on M1** | Default "Previews in Finder" format = x265 slow, 8 fps at 1080p50 | For the "Send it" intent, default to VideoToolbox at a VMAF-searched `-q:v` (already supported) and accept larger files; keep x265 slow for "Save space" and "Archive". Show the time difference so the user chooses knowingly. |
| **Parallelism** | One job at a time; the engine assumes the encoder saturates the CPU | Hardware jobs barely use the CPU: run them in parallel with a software job. Run analysis and VMAF of job *n* during the encode of job *n+1*. |
| **Audio** | AAC (Apple, CVBR) or Opus, dual-mono detection, passthrough when already efficient — good | Add EBU R128 loudness normalisation (`loudnorm`, two-pass) as an option ("Even out volume"), not a default. |
| **HDR** | HDR10 mastering and content-light metadata survive on x265 and SVT-AV1 **[Test]**; Dolby Vision dropped; no SDR conversion | Add HDR → SDR tone mapping (`zscale`+`tonemap` or `libplacebo`) for "Plays everywhere" and for H.264. Keep the DV base layer, and say clearly in the UI that DV becomes HDR10/HLG. |
| **Rate control** | Verify-and-correct loop guarantees ≤ target; SVT-AV1 two-pass undershoots by a median 6 % **[Report]** | After an undershoot of more than 10 %, re-run pass 2 at the corrected bitrate if time allows (Recommended/Smallest modes), so users get the quality they paid for in megabytes. |

### C3. Honest communication of quality and size

What Digby already does right: estimates are labelled as estimates, "measured" vs "scaled" is distinguished, and "Not measured" is shown when measurement is off. Keep all of it.

What to add **[Rec]**:

* **Ranges, not points, for estimates:** "≈ 38–46 MB" when scaled from ratios, a single figure only when measured on samples. Track the actual error per job and widen or narrow the range from real data.
* **Time estimates that include the analysis**, not just the encode.
* **A plain-language confidence line** on results: "Measured on every 10th frame of the whole video."
* **Never present a guarantee the engine can't keep.** The size guarantee is real. Quality is a *target*, so say "aims for", and report the measured value afterwards.

---

## D. Gap analysis

### D1. Correctness defects found during the audit (fix first)

| # | Defect | Evidence | Severity |
|---|---|---|---|
| 1 | All subtitle tracks are dropped; README says text subtitles are kept | **[Test]** `rich.mov` with a `mov_text` track → output has none. **[Code]** `encodeArgs` maps only `0:v:0` and one audio stream. | High: data loss and a false claim |
| 2 | Only the first audio track survives; `AdvancedSettings.keepAllAudioTracks` is dead code | **[Test]** French "Commentary" track lost. **[Code]** no reader of `keepAllAudioTracks`. | High |
| 3 | Creation date and Apple metadata (`com.apple.quicktime.location.ISO6709`, make, model) are lost | **[Test]** `creation_time` and all `com.apple.*` keys missing from output; only the 3GP `location` survived | High for phone videos (Photos timeline, Maps) |
| 4 | Text guard "On" with no text still raises the VMAF target by 1, disables grain synthesis, and shows a green "Text kept readable" chip | **[Code]** `EncodePlan.swift` target `+1` when `guardPlan.active`; **[Test: render]** chip shown with "no text detected" | Medium: costs ~10 % size for nothing and says something untrue |
| 5 | Screen recordings delivered at 83–86 % legibility while the guard's required accuracy is 97 %, with the test marked as passed | **[Report]** `screen-balanced`, `screen-3MB` | Medium: the guard's claim isn't met and the suite doesn't catch it |
| 6 | Quality rating ignores resolution reduction | **[Code]** `QualityMeter.measure` scales the reference to output size | Medium: misleading |
| 7 | "Preview Studio…" button shown twice on one screen | **[Test: render]** | Low |
| 8 | Settings persist from the last session (target size, Best Possible, text guard On), so the next new video silently inherits an unusual configuration | **[Test: render]** a fresh launch opened with "Under 8 MB", "Best Possible" and guard "On" | Medium: surprising for novices |

### D2. Missing essential features

1. Keep all streams (audio, subtitles, chapters, metadata) by default.
2. A fast default path (seconds to a few minutes for typical phone clips).
3. Trim (start/end). It's the most common "make this smaller" companion task.
4. Rotate and crop, including automatic removal of black bars.
5. Share after compressing (Share menu, AirDrop, Mail, Messages, "Copy file").
6. Destination presets that match the current limits (see E1.4).
7. Notarisation and in-app updates.
8. Accessibility pass (B3).

### D3. Missing advanced features

MKV / MOV / WebM containers; ProRes (VideoToolbox) and FFV1 for archival intermediates; HDR → SDR; Dolby Vision passthrough; loudness normalisation; optional denoise; per-track selection (choose languages, set default/forced); burn-in subtitles; output filename templates; watch folders; App Intents / Shortcuts; pause/resume of a running job; queue reordering; parallel hardware jobs; scheduling ("start at 1 a.m." / "only on power").

### D4. Technical and architectural limitations

| Limitation | Size of change |
|---|---|
| Stream mapping hard-coded in `encodeArgs` | **Small.** Add a `StreamPlan` beside `AudioPlan`, produced by the pure planner. |
| Metadata via `-map_metadata 0` into MP4 drops Apple keys | **Small.** `-movflags +use_metadata_tags`, explicit `creation_time`, or rewrite metadata with AVFoundation after muxing. Test with Photos import. |
| Single-job runner | **Medium.** The runner in `AppModel` becomes a scheduler with resource classes (CPU-heavy vs media engine). The engine is already re-entrant per job. |
| No pause | **Medium.** SIGSTOP/SIGCONT on the registered FFmpeg processes works for the encode stage; persist stage state for resume after quit. |
| Container fixed to MP4 in `outputURL` and muxing | **Small–medium.** Container choice in the plan; per-container stream rules (e.g. `mov_text` in MP4, SRT/ASS copy in MKV, Opus-in-MP4 compatibility). |
| Trim/crop/rotate | **Small in the engine** (filters + `-ss/-to` already used for samples). **Medium in the UI** (a scrubber with in/out points and a crop overlay). |
| Measurement as a blocking stage | **Small.** Make it asynchronous and optional per intent. |
| Settings model mixes user intent and engine parameters | **Medium.** Add a thin `Intent` layer that resolves to `CompressionSettings`. Don't replace `CompressionSettings`. |

Nothing here needs a rewrite. The planner, encoder back-ends, optimiser primitives, versions model and replacer all stay.

### D5. Opportunities for meaningful differentiation

1. **"Fit, guaranteed" plus "how it will look"**: the only app that guarantees the size *and* shows measured quality before and after.
2. **Text guard**, generalised into "Protect: text · faces · fine detail", using on-device Vision face detection to raise quality on faces in talking-head video.
3. **Destination intelligence**: "Fit for Discord / email / WhatsApp / iMessage", with limits kept up to date and the right compatibility profile (H.264 + AAC where the receiver might be old).
4. **"Clean up my library"**: scan a folder or the Photos library, show "These 312 videos could free 84 GB at Excellent quality", and do it safely (Trash + Restore). Nobody does this well, and the app already has the safe-replace machinery.
5. **Explainable decisions**: "We picked 720p because at 25 MB it measured better than 1080p (VMAF 91 vs 86)". The notes already contain this. Show it as a sentence on the result, not a log line.

---

## E. Gold-standard product specification

### E1. Essential (expected of any competitive product)

**E1.1 Intent-first front door.** The empty window shows goal tiles, each one a drop target:

| Tile | Behind the scenes |
|---|---|
| **Make it smaller** (default) | Balanced, previewable format, fast path when the source is big |
| **Fit under a size…** | Target-size mode with a field and destination chips (Email, Discord, WhatsApp, Custom) |
| **Save space on my Mac** | Recommended effort, replace-with-Trash offered, skip-if-small on |
| **Share anywhere** | H.264/AAC, SDR, ≤ 1080p |
| **Archive (best quality)** | High/Maximum, smallest efficient format, keep all streams |
| **Custom…** | Opens the current full settings |

After a drop: one card with the thumbnail, the chosen goal, **one "Smaller ↔ Better" control** (the five levels, with the estimate on the control itself), the destination, and **Compress**. Everything else lives in an **inspector** (⌥⌘I), organised as Picture · Sound · Tracks & info · Engine.

**E1.2 Fast by default.** Target: a 1-minute 4K iPhone clip compresses in under a minute in the default path on M1. Achieved by hardware encode with a 2-probe search at reduced resolution, measurement optional and asynchronous. "Recommended" and "Smallest possible" stay available, with their time cost shown.

**E1.3 Lossless pass-through of everything that isn't the picture.** All audio tracks (re-encoded or copied), all text subtitles (converted to `mov_text` in MP4), chapters, creation date, location, make/model and other Apple keys, rotation, HDR10/HLG signalling. An "Info" row on the result confirms it: "Kept: 2 audio tracks · subtitles (English) · chapters · date & location".

**E1.4 Destination presets with real limits**, stored as data (JSON in the bundle, with a "last checked" date), not code. Current values need checking against official pages before shipping: Gmail 25 MB total **[3rd-party, consistent]**; Discord's free tier was 10 MB from late 2024, and later reports say it was raised to 20 MB **[3rd-party, conflicting]**; WhatsApp figures conflict (16 MB vs 2 GB as a document) **[3rd-party]**.

**E1.5 Trim, crop, rotate**, with a frame-accurate scrubber, and automatic black-bar detection offered as a one-click suggestion.

**E1.6 Results you can act on:** Play, Compare, Share, Show in Finder, "Make it smaller", "Make it better", Move original to Trash, Restore.

**E1.7 Queue basics:** reorder, pause/resume, cancel, clear finished, notifications, Dock progress, keep awake (already done), resume after quit (already done).

**E1.8 Trustworthy distribution:** Developer ID signing, notarisation, hardened runtime, Sparkle (or equivalent) updates, a privacy statement ("nothing leaves your Mac"), crash reporting only if opt-in.

**E1.9 Accessibility:** full VoiceOver labels, values and selected states; Full Keyboard Access; colour never the sole carrier of meaning; Reduce Motion everywhere; announcements on completion and failure.

### E2. Important (substantially better)

* **Estimates with ranges, including analysis time**, and a "fit" indicator on target-size mode before starting ("Fits easily", "Tight: expect softness", "Won't fit at 1080p: 720p suggested").
* **Smarter recommendations on drop:** "This 2.1 GB screen recording would be ~90 MB at Excellent quality", and one-click accept.
* **Finder Quick Action and Share extension** ("Compress with Digby", using the last goal), **App Intents** for Shortcuts, **Services** menu.
* **Watch folders** with a goal per folder, running at low priority.
* **Parallel jobs** (hardware alongside software), and a **low-power mode** (fewer threads, Efficiency cores) like Permute 4 **[Source]**.
* **Library clean-up** (D5.4), Finder folders first, Photos later.
* **Loudness normalisation** and **HDR → SDR** as single toggles with plain names: "Even out volume", "Convert HDR for older screens".
* **Versions** (already built) promoted as "Make several sizes", with destination chips.

### E3. Advanced (professional-grade)

* MKV, MOV, WebM output; ProRes (VideoToolbox) and FFV1 for archival/intermediate.
* Per-track control: select, reorder, set language/title/default/forced, burn-in a subtitle.
* Dolby Vision passthrough (profile 8.x via `dovi_tool`-style handling or FFmpeg's passthrough) and HDR10+.
* Optional denoise (`hqdn3d`/`nlmeans`) and sharpening, off by default and measured when on.
* Filename templates (`{name} ({goal}, {height}p).{ext}`), output folder rules, "mirror folder structure".
* Scheduling and "run only on power / when idle".
* Stable CLI with JSON output (exists) plus an exit-code contract, documented for scripting.
* Exportable/importable presets (Permute 4.1 added this **[Source]**).
* A "Technical report" for each job: the exact FFmpeg command lines, encoder versions, measurements (for professionals who must justify settings).

### E4. Differentiators (genuinely exceptional)

1. **Size guaranteed, quality measured, choice explained**, as one experience: drop → "Fits in 25 MB. Will look Very Good (measured). We chose 720p because…" → Compress.
2. **Protect what matters:** text (exists), faces, and fine detail, each checked after encoding with on-device Vision, and reported.
3. **Visual decision instead of numeric decision:** Preview Studio, simplified into a "pick the smallest one that still looks good to you" strip of 3–4 frames at real sizes. This is the honest answer to "VMAF isn't perception": let the user's eye make the final call when it matters.
4. **Library clean-up with an undo**: saved-space accounting, Trash-based replacement, Restore.
5. **Self-calibrating estimates**: every finished job feeds back its estimate error, so estimates on *this* Mac get tighter over time (local only).

---

## F. Prioritised roadmap

Rough effort for one experienced Swift developer. The order follows dependencies.

### Phase 0 — Decisions and correctness (1–2 weeks)

| Item | Why now | Effort |
|---|---|---|
| Decide the name (Digby vs Digby) and freeze it | Everything user-visible and the website depend on it | Decision |
| Decide the business and licensing model (see G2) | Determines whether x264/x265 can ship, and the App Store | Decision |
| Fix D1 #1–#3: `StreamPlan` for all audio, subtitles and metadata; Photos import test | Silent data loss is unacceptable | 3–5 days |
| Fix D1 #4, #6, #7, #8; make the integration suite fail on legibility below threshold (#5) | Honesty | 2–3 days |
| Correct the README's subtitle and track claims until fixed | Honesty | 1 hour |
| Blind visual test: SVT-AV1 `tune=0` vs `tune=1`, and grain synthesis on/off | Before any further tuning rests on VMAF | 2–3 days |

### Phase 1 — Speed (2–3 weeks) — highest user impact

* Asynchronous, optional, cheaper full-file measurement (≤ 1080p, heavier subsampling, overlapped with the next job).
* Fast path: hardware encode + 2-probe search on downscaled samples for "Make it smaller" and "Share anywhere".
* Search at reduced effort with a calibrated offset; cross-session cache by content fingerprint.
* Estimates never blocked by the queue; time estimates include analysis.
* Parallel scheduler (hardware + software jobs), pause/resume.
* Success criterion: a 1-minute 4K iPhone clip under 60 s on M1 in the default path; record before/after in `Benchmarks/`.

### Phase 2 — Intent-first UX and accessibility (3–4 weeks)

* Goal tiles, single "Smaller ↔ Better" control, inspector for the rest, renamed concepts (B4).
* Results: Share, "Smaller/Better", kept-streams line, two-part quality line.
* Destination presets as data.
* Full accessibility pass (B3) as a release gate.
* First-run: one sheet of three cards (what it does, where files go, that originals are never changed), no tour.

### Phase 3 — Everyday editing (2–3 weeks)

* Trim with scrubber; crop with auto black-bar detection; rotate/flip.
* HDR → SDR; loudness normalisation.
* Finder Quick Action, Share extension, App Intents.

### Phase 4 — Distribution and trust (1–2 weeks, can run alongside Phases 2–3)

* Developer ID, notarisation, hardened runtime, updates, GPL source offer on the website (already noted in the README), privacy page.
* Consider lowering the macOS floor only if the market needs it (Permute 4 made the same macOS 26 / Apple Silicon choice **[Source]**, so this is defensible).

### Phase 5 — Professional depth and differentiators (ongoing)

* Containers, ProRes/FFV1, per-track control, Dolby Vision, filename templates, watch folders, scheduling, preset import/export, technical report.
* Face-protection guard; library clean-up; self-calibrating estimates; simplified visual picker.

### Risks to watch

| Risk | Mitigation |
|---|---|
| Faster defaults produce visibly worse files | Keep measurement on samples; re-run the blind test after Phase 1 |
| Metadata handling differs between Photos, Finder and other tools | Test matrix: Photos import, Finder Get Info, QuickTime, `exiftool` |
| Parallel jobs cause memory pressure on 8 GB Macs | Resource classes plus a memory-aware limit |
| FFmpeg/SVT-AV1 upgrades change tuning | The benchmark harness exists; make re-running it part of each engine upgrade |
| Hardware differences (M1 vs M3/M4/M5) skew estimates | Per-chip calibration tables; self-calibration (E4.5) |

---

## G. Final assessment

### G1. How far from the standard?

| Dimension | Today | Gold standard | Gap |
|---|---|---|---|
| Compression intelligence | Best in class | Best in class, validated by eye | Small: visual validation of tuning |
| Output fidelity (streams, metadata) | Below HandBrake | Lossless pass-through of everything non-picture | **Large but cheap to close** |
| Speed | Far behind consumer apps | Seconds to minutes by default | **Large** |
| Novice UX | Clear language, too many controls | Goal → one control → done | **Large** |
| Expert depth | Good engine controls; no editing, few containers | Inspector with tracks, containers, filters | Medium |
| Honesty | Strong, with a few misleading edges | Strong everywhere | Small |
| Accessibility | Largely unaddressed | Release-gated | **Large but well understood** |
| Distribution and trust | Unsigned, no updates | Notarised, auto-updating | Medium |
| Architecture | Clean and extensible | Same | Small: preserve |

An experienced reviewer today would praise the engine and the honesty, then criticise the waiting time, the lost subtitles, tracks and dates, the settings overload and the Gatekeeper warning. Those four criticisms are what stand between this app and the gold standard.

### G2. Decisions you need to make before development continues

1. **Name.** `main` says Digby; the working tree says Digby. Each phase above touches user-facing text, so decide first.
2. **Free or paid, and licensing.** The bundled FFmpeg includes GPL x264/x265. Free and open source (MIT app + GPL FFmpeg with a source offer) is fine as is. A paid closed-source app distributed outside the App Store can still ship GPL FFmpeg as a separate process if the source offer is honoured, but get legal advice. **The Mac App Store is effectively ruled out** with GPL components. Paid distribution also raises HEVC/H.264 patent-licensing questions that a free open-source project usually doesn't face. Options: keep GPL FFmpeg (fastest), or build an LGPL FFmpeg with SVT-AV1 (BSD+patent licence) and VideoToolbox for HEVC/H.264 and drop x264/x265 (cleaner licensing, but loses x265's efficiency on M1/M2 where AV1 doesn't preview).
3. **Default philosophy: fastest acceptable vs smallest possible.** I recommend that the default intent ("Make it smaller") favours speed with measured quality, and that "Save space" and "Archive" favour efficiency. This is the single biggest UX lever.
4. **Is VMAF the product's judge, or a guide?** I recommend: a guide for automation, with the user's eye (Preview Studio, simplified) as the final judge when it matters, and every VMAF-driven tuning decision re-checked visually.
5. **Scope: compressor or converter?** Stay a compressor that is excellent at everything around compression (trim, crop, tracks, sharing). Don't become Permute (PDFs, images, text) or Compressor (immersive video, broadcast formats).
6. **Platform floor.** macOS 26 + Apple Silicon only. Permute 4 made the same call, so it's defensible; but confirm, because it shapes which APIs (and which media engines) you design for.

---

## Appendix 1. What to preserve (good existing decisions)

* `DigbyCore` engine independent of the UI; the UI never builds an FFmpeg command line.
* FFmpeg as a separate process (crash isolation, licence separation), with a cancellable process registry.
* `EncodePlanner` as a pure, unit-tested function; encoder back-ends that only map parameters to arguments.
* Benchmark-derived constants centralised in `EngineTuning`, with the harness in `Benchmarks/`.
* Audio-first target-size budgeting, per-encoder safety margins, verify-and-correct loop.
* Frame-index VMAF pairing (`setpts=N`), p5 tempering of the rating.
* Atomic partial files; never writing to the source path; Trash-based replacement with restore; the `DigbyMarker` xattr.
* Dual-mono detection, efficient-AAC passthrough, never exceeding the source's audio bitrate.
* HDR10 colour signalling via `setparams` (verified to keep mastering metadata).
* The versions model and Preview Studio, as the engine behind the differentiators in E4.
* Plain-English explanations for every option, and labelled estimates.

## Appendix 2. Test evidence

All tests used the bundled helpers in `build/Digby Video Compressor.app/Contents/Helpers/` (FFmpeg 9.0.2) on an M1 Max under load (load average 9–30).

**Stream and metadata preservation.** Source `rich.mov` (10 s, 1080p H.264) with 2 AAC tracks (eng, fra "Commentary"), a `mov_text` English subtitle track, 2 chapters, `creation_time=2024-06-01T10:20:30Z`, `com.apple.quicktime.location.ISO6709`, `make=Apple`, `model=iPhone 15 Pro`. `digby compress rich.mov --quality balanced`:

* Output streams: video (HEVC), **one** audio (eng), a data stream. Subtitle track and second audio track **missing**.
* Chapters: kept.
* Format tags: `creation_time` **missing**; all `com.apple.quicktime.*` **missing**; 3GP `location` kept.
* Time 48.5 s for 10 s of 1080p; VMAF 93.2 (sample prediction 93.22, final 93.20: whole clip was the sample).

**HDR10 metadata.** Source re-encoded with x265 `master-display` and `max-cll=1000,400`. Both `--priority apple` (x265) and `--smallest` (SVT-AV1) outputs kept PQ/BT.2020, 10-bit, mastering-display and content-light-level side data.

**Speed and efficiency, 12 s of 3840 × 2160 H.264 at 26.6 Mbps (landscape):**

| Run | Time | Output | VMAF (p5) | Settings |
|---|---:|---:|---|---|
| Default (Smart, Balanced, Finder-safe) | 556 s | 4.0 MB | 93.0 (92.5) | x265 slow, CRF 30 |
| "Fastest" (hardware) | 210 s | 9.7 MB | 93.3 (93.1) | VideoToolbox HEVC q 62 |
| Raw `hevc_videotoolbox -q:v 62`, no analysis or measurement | 4.3 s | 13.8 MB* | — | — |
| `digby analyze` only | 6.5 s | — | — | — |

\* Includes the copied 254 kbps audio, and lacks Digby's 10 s GOP setting, so it's not directly size-comparable; the point is the time.

**UI render.** Offscreen render (`DIGBY_RENDER_DETAIL`) of the detail pane for the 4K clip after 75 s: estimate still "Measuring sample scenes…"; "Text kept readable" chip shown while the row says "no text detected"; two "Preview Studio…" buttons; settings inherited from the previous session (target 8 MB, Best Possible, text guard On).

## Appendix 3. Sources

* HandBrake releases (1.10.0 – 1.11.2): https://github.com/HandBrake/HandBrake/releases
* HandBrake 1.10 coverage (Social 10MB presets, metadata passthrough): https://linuxiac.com/handbrake-1-10-arrives-with-new-presets-metadata-improvements/
* HandBrake forum, target size removed: https://forum.handbrake.fr/viewtopic.php?p=142984
* HandBrake RF documentation: https://handbrake.fr/docs/en/1.6.0/workflow/adjust-quality.html
* RF confusion (forum): https://forum.videohelp.com/showthread.php?p=2537799
* Apple Compressor release notes: https://support.apple.com/102745
* Compressor App Store listing: https://apps.apple.com/us/app/compressor/id424390742?mt=12
* Permute 4 product page and upgrade notes: https://software.charliemonroe.net/permute/ · https://software.charliemonroe.net/upgrade/permute/v4/
* Permute 4 App Store: https://apps.apple.com/us/app/permute-4/id6774079417?mt=12
* Smol vs Permute comparison: https://smolmac.com/compare/permute-alternative
* Shutter Encoder: https://www.shutterencoder.com/
* Compresto: https://compresto.app/ · pricing history: https://compresto.app/blog/compresto-1-3-updated-pricing-hardware-acceleration-and-additional-features
* VideoProc / compressor comparison (3rd-party): https://comparitech.com/utilities/best-video-compressors-for-windows-and-mac
* Movavi reviews (3rd-party): https://unifab.ai/resource/movavi-video-converter-review · https://www.capterra.com/p/233493/Movavi-Video-Converter/reviews/
* Adobe Media Encoder what's new (Jan 2026): https://helpx.adobe.com/media-encoder/using/whats-new/2026.html
* Finder "Encode Selected Video Files" reports: https://discussions.apple.com/thread/255433354
* SVT-AV1 changelog: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/CHANGELOG.md
* SVT-AV1 4.0 (AOMedia): https://aomedia.org/blog%20posts/SVT-AV1-4_0-Boasts-Major-API-Updates/
* Banding vs VMAF (Netflix research): https://arxiv.org/pdf/2202.11038
* VMAF NEG explained: https://www.forasoft.com/learn/video-quality/articles-vqm/vmaf-neg-explained
* Discord limits: https://dataconomy.com/2024/09/05/discord-upload-limit-10mb-per-file/ · https://www.dexerto.com/entertainment/discord-raises-free-upload-limit-to-20mb-after-lowering-it-two-years-ago-3398251/

---

## Status: what 1.2 (branch `gold-standard`) changed

| Audit item | Status |
|---|---|
| D1 #1 Subtitles dropped | **Fixed.** Text subtitles kept (MP4/MOV as `mov_text`, MKV as-is); picture subtitles kept in MKV, otherwise named as left out. Verified with ffprobe. |
| D1 #2 Extra audio tracks dropped | **Fixed.** Every track kept by default (languages, titles, which one plays by default); "Main track only" option. `keepAllAudioTracks` replaced by `audioTracks`. |
| D1 #3 Date, place, camera lost | **Fixed.** QuickTime sources stay `.mov` and get `©xyz`/`©mak`/`©mod` + `creation_time`; verified with AVFoundation (what Photos/Finder read). MP4 keeps the date. Option to strip them. Output files also take the original's Finder creation date. |
| D1 #4 Text guard "On" without text | **Fixed.** No +1 VMAF, no grain change, no "Text kept readable" chip when nothing was found. |
| D1 #5 Suite passed text below 97 % | **Fixed.** Suite fails when a guarded file is below 97 % *and* the user wasn't warned. |
| D1 #6 Rating ignores resolution | **Fixed (honest wording).** Result shows "was 3840 × 2160" and says the rating is at the new size. |
| D1 #7 Duplicate Preview button | **Fixed.** |
| D1 #8 Settings inherited silently | **Improved.** New videos start from the remembered goal (visible as the selected tile); trim/crop never carry over. |
| Speed | **Improved.** Faster-preset search + one calibration trial, 12 s samples, hardware encode-measure-correct, ≤ 900 scored frames with hardware decoding, fast near-lossless text reference, media-engine jobs in parallel. Measured: "Quick" (hardware) on 12 s 4K went from 210 s to 76 s under heavy load. See the before/after table below. |
| Goal-first front door | **Done.** Six goals, one Smaller ↔ Better control, everything else under "More options", renamed concepts. |
| Trim, crop (auto black bars), rotate, mirror | **Done** (editor sheet ⌘E, CLI flags). |
| Loudness normalisation, HDR → SDR, denoise | **Done.** Loudness verified −21.8 → −16.0 LUFS. HDR → SDR uses FFmpeg's scaler (see README limitation). "Plays everywhere" + HDR now converts to SDR H.264. |
| Share, Finder service, VoiceOver | **Done.** Share button; Finder → Services → "Compress with Digby"; VoiceOver announcements; selected states and labels on custom controls. |
| MKV / MOV output | **Done.** |
| Destination presets as data | **Done** (`Destination`, with a "checked" date). |
| Notarisation, auto-update | **Not done: needs your Apple Developer ID** (and a decision on an update channel). |
| Blind visual test of SVT-AV1 `tune` and grain | **Not done: needs human eyes.** Still the most important open quality question. |
| Name, licensing / business model | **Your decision.** This branch keeps "Digby" (as on `main`). |
| App Intents (Shortcuts) | **Not done:** App Intents metadata needs Xcode's build tools; this project builds with Command Line Tools only. The Finder service covers the same "from anywhere" need for now. |

### Before/after measurements (M1 Max, shared with other heavy work; indicative)

| Clip, settings | 1.1 | 1.2 | Notes |
|---|---|---|---|
| 12 s 4K landscape, **Quick** (hardware) | 210 s, 9.7 MB, VMAF 93.3 | **76 s**, 9.7 MB, VMAF 93.3 | No sample search; measured and kept (on target) |
| 24 s 1080p50 crowd, **default** (HEVC, Balanced) | 2,585 s, 66.2 MB, VMAF 95.7 | **1,591 s**, 75.2 MB, VMAF 96.7 | Search: ~15 min → ~6.5 min. The text guard then chased OCR noise (moving shirt numbers read 54 % even near-losslessly) and raised quality twice; **fixed afterwards**: text that doesn't read reliably near-losslessly no longer drives quality or warnings. |
| 24 s 1080p50 crowd, **Quick** (hardware) | skipped ("not smaller than the original") | **178 s**, 88.3 MB, VMAF 94.2 | 1.1 had no correction step and gave up |

What the measurements showed about the faster search: x265 *medium* and *slow* differ by up to **3 VMAF at the same CRF** on this clip (23.5: 94.5 vs 97.5), so the calibration trial at the real preset is essential, not optional.

Still slow in absolute terms: x265 *slow* on an M1 encodes 1080p50 detailed footage at a few frames per second, and the search adds about one more encode. For people who want speed, the **Quick** goal is now a real option (seconds, measured, corrected); the remaining lever is defaulting "Make it smaller" to the media engine on long videos, which is a product decision (see G2 #3).

Integration suite (release build, 16 cases incl. 4 new): **16/16 pass** (`Tests/integration/REPORT.md`). Notable: screen
recordings at Balanced now read **98 %** (1.1: 83 %), and Fast mode ("Fast" effort) can still miss its target (HDR clip:
VMAF 87 at Balanced), as documented, because it has nothing to measure.
