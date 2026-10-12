# Quiet color roles — 0.8.3

The app uses its original neutral shell: light gray/white in light mode,
charcoal in dark mode, with its restrained original teal controls. The terminal
inherits the terminal background (ANSI default background), with soft gray text, subdued gray borders, and a slate
`#303640` selected row. Neither uses Forest as a primary surface or Signal as
a full-row fill.

Mëngøh Labs colors are reserved for data visualization:

| Data | Color |
| --- | --- |
| CPU | Moss `#3B8D5D` |
| Memory | Amber `#D99422` |
| GPU | Research Blue `#3880BD` |
| Network receive | Iris `#7967B8` |
| Network transmit | Fault `#C94B4B` |
| Selected process chart | Signal `#72D572` |

Tokens are shared through `Sources/QuietCore/MengohPalette.swift`.
Labels remain neutral; series colors stay stable across the view. Canonical
Glyph artwork and the icon retain their original colors.

The CLI uses 24-bit ANSI for exact colors and resets styles on exit/suspend.
