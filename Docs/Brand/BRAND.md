# Digby Video Compressor brand

**Name:** Digby Video Compressor (short: Digby). Never all caps in running text.
**Tagline:** Less weight. Same picture.
**Owner line:** © 2026 Digby. The product is credited to no person.
**Wordmark:** see `../../brand/README.md` (Schibsted Grotesk 800, −0.05em; `DigbyLockup` in the app).

## Icon: Chevron
Two chevrons press inward onto one bright dawn line, on a midnight-to-dawn sky. Its sibling, Digby Video
Downloader, uses the same chevrons pouring down onto the same line in ink, teal and amber.
Masters: `../../brand/icons/compressor-icon.svg` (+ `-1024.png`). `Resources/AppIcon.svg` is a copy.
To regenerate every size (app iconset/icns, sites, brand), run `../../design/icons/install.sh`; it draws the
icon natively with `design/icons/render_chevron.swift` (macOS grid: 1024 canvas, 824 squircle body).

## Colour
| token | light | dark | use |
|---|---|---|---|
| Sky (accent) | #3A6AAE | #8FB6E8 | buttons, selection, progress |
| Dawn | #D98E62 | #F0B28C | arrival only: convergence point, "saved" figures |
| Altitude | #14294D | | icon/sky gradient top, About band |
| Haze | #BFD3EA | | sky gradient |
| Dawn (fixed) | #F2C2A0 | | sky gradient horizon, icon bar |

Semantic colours (warnings, errors, success) stay the system's own. Dawn is never a warning colour.

## Type
In the app: SF Pro (system), Dynamic Type, tabular figures for sizes and percentages. Display text
(drop zone, About, progress %) uses SF Pro Light/Ultralight. Marketing: Hanken Grotesk Light (OFL) for
display, SF Pro / Instrument Sans for text.

## Motion
* Waiting for a drop: the Altitude sky (the website hero) sits behind the drop zone.
* Compressing: streaks draw toward the point as progress advances (`ConvergenceProgress`), echoing the hero.
* Done: the Chevron mark next to the result.
All motion respects Reduce Motion.
