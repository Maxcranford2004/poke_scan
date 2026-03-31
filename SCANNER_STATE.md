# Scanner Stable State

This checkpoint is the known-good scanner state.

Includes:
- OCR species alias recovery
- Mega-form recovery
- trusted collector-number parsing
- collector source trust gating
- ambiguity guard for same-family variants
- visual tiebreak for ambiguous same-family hit cards

Known verified scans:
- Mega Froslass ex -> correct
- Mega Dragonite ex #271/217 -> correct

Protection rule:
Do not rewrite scanner flow from scratch.
Any future scanner changes must be incremental and reversible from this checkpoint.
