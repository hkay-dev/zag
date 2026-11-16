---
type: log
summary: Changed - Foundry registered the private, licensed Zag site in Draft, linked zag-hkay and ignored the preview site.
project: zag
sprint: 01M7JER5HXJC4VWSVHY6DZ7D6Q
window: 2026-11-16T15:43:24Z/2026-11-16T16:06:02Z
tickets: [zag#f7w7]
---

# Register Zag site and link its Netlify site

# Register Zag site and link its Netlify site

Changed: Foundry registered the private, licensed Zag site in Draft, linked zag-hkay and ignored the preview site. The site check passed and the export contained no source maps. Foundry marked the ticket Shipped after Built; Netlify reported the same published deploy. The active-run guard refused the Go live dry-run. Foundry also refused Pause, while Finish would push; I recorded this conflict on foundry#e1f6 and left the run running.
Try: Open Zag's Site card in Anvil and check Draft and zag-hkay; not tried yet. You control Go live and the site channel's Ship it action.
