# AgentGrid App Icon Design

## Goal

Replace the utilitarian four-pane icon with a polished macOS app icon that still reads immediately as four terminal sessions in one grid.

Victor explicitly delegated the creative direction by asking for a good generated icon. The implementation preserves the product's existing four-pane identity and does not introduce provider logos or a new brand name.

## Evidence and references

- Existing truth: `Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` — preserve the 2×2 terminal concept and green, blue, amber, violet pane order.
- `grammar-of-ornament.jpg` (Owen Jones, public domain) — composition job only: disciplined modular symmetry and reduced repeat geometry.
- `mela-iphone.png` (Silvio Rizzi, private reference only) — material/lighting job only: centered-object clarity, generous margins, soft rounded geometry, and controlled dimensional light.
- Generated direction board: `agent-grid-icon-direction.png` — keep the graphite foundation, four-color terminal identity, and responsive simplification; reduce the center glow and gloss; reject the feeling of four unrelated buttons.

References inform visual properties only. The final geometry, palette, mark, and app identity are original.

## Dynamic design contract

- Experience thesis: four autonomous terminals snap into one calm, unified command surface.
- Signature moment: four colored pane layers visually converge at the center and settle into a crisp 2×2 grid.
- Motion language: static asset with an inward convergence vector; no runtime animation is added.
- Depth tier: Tier 1 layered 2.5D because a shallow graphite shell, inset panes, and restrained lighting improve Dock recognition without runtime cost.
- State coverage: 1024, 512, 256, 128, 64, 32, and 16 px raster adaptations; larger sizes retain material detail and smaller sizes prioritize silhouette and contrast.
- Performance budget: no runtime work; keep the installed bundle lightweight and use only the required raster assets.
- Reduced-motion equivalent: the icon is static and communicates the same four-pane meaning without animation.
- Fallback: macOS asset catalog provides every required size; no network or generated-at-runtime dependency.

## Production direction

- One centered macOS squircle on transparent canvas with a safe outer margin.
- Near-black graphite shell and shallow inset pane geometry.
- Four restrained accents in fixed reading order: emerald, blue, amber, violet.
- One minimal terminal chevron/cursor motif per quadrant, simplified at small sizes.
- No text, letters, provider logos, screenshots, neon bloom, watermark, or decorative micro-detail.

## Generation receipt

- Built-in concept pass: `exec-c098c030-b05b-4d69-9ea4-e55ddb8760e7.png`, preserved as `agent-grid-icon-direction.png`.
- Built-in production pass: `exec-daafe352-b6aa-4e0f-8cc5-c636a075649a.png`; selected for its unified shell, restrained depth, strong silhouette, and exact color order.
- Built-in background correction: `exec-132cc1bf-8404-4f15-85d3-95a5ada64283.png`; changed only the exterior canvas to a flat key color.
- Deterministic finishing: connected-background alpha extraction at 30% tolerance, then high-quality resize to the 1024 px sRGB RGBA master.
- Master SHA-256: `09ef80f0f1499364e5a825f9621402d6ac504ef2546d6440da5778527630f7f2`.

The production prompt requested one centered graphite macOS squircle, four integrated terminal panes, fixed emerald/blue/amber/violet order, one prompt chevron and cursor line per quadrant, shallow 2.5D light, strong 16 px recognition, and no text, provider logos, screenshots, neon bloom, watermark, or micro-detail.

## Validation

Inspect the master at native resolution and every derived size. Build the Release app, inspect the compiled `.icns`, reinstall the bundle, refresh LaunchServices/Dock if necessary, and visually verify the exact installed icon in Finder or the Dock. Re-run the full existing test suite and confirm the app's terminal behavior is unchanged.
