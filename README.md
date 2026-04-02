# Poke Scan

Poke Scan is a Flutter app for scanning Pokémon cards, matching them against card data, and adding them to a personal collection.

Current major features:
- camera and photo-library card scanning
- OCR-assisted scanner with fallback search and variant disambiguation
- manual search and search results flow
- card details with pricing links and market-value enrichment
- collection tracking, set progress, XP, and achievements
- Firebase auth and Firestore-backed owned-card sync

Scanner note:
- the scanner flow is checkpointed in a known-good state
- do not rewrite the scanner flow casually
- future scanner changes should be incremental and reversible
