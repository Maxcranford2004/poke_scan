import 'package:flutter/foundation.dart';
import 'pokemon_models.dart';
import 'pokemon_tcg_api.dart';

/// One owned card entry (duplicates allowed via entryId).
class CollectionEntry {
  final String entryId;
  final PokemonCardResult card;
  final DateTime addedAt;

  final int userGrade; // 1..10
  final String? finish;
  final String? localPhotoPath;

  final double? marketAtSave;
  final double? highAtSave;
  final double? estLowAtSave;
  final double? estHighAtSave;

  CollectionEntry({
    required this.entryId,
    required this.card,
    required this.addedAt,
    this.userGrade = 8,
    this.finish,
    this.localPhotoPath,
    this.marketAtSave,
    this.highAtSave,
    this.estLowAtSave,
    this.estHighAtSave,
  });

  double? get estimatedMid {
    if (estLowAtSave == null || estHighAtSave == null) return null;
    return (estLowAtSave! + estHighAtSave!) / 2.0;
  }
}

/// Summary used by your Sets list UI in main.dart.
class SetSummary {
  final String setKey; // keep the name main.dart expects
  final String setName;

  final int ownedInstances; // including duplicates
  final int ownedUniqueSlots; // distinct card ids
  final int? printedTotal;

  SetSummary({
    required this.setKey,
    required this.setName,
    required this.ownedInstances,
    required this.ownedUniqueSlots,
    required this.printedTotal,
  });

  /// Some older parts of main.dart might use setId wording.
  /// Make it NON-null to avoid the String? error you hit.
  String get setId => setKey;

  double get progress {
    final total = printedTotal;
    if (total == null || total <= 0) return 0;
    return ownedUniqueSlots / total;
  }

  String get progressText {
    final total = printedTotal;
    if (total == null || total <= 0) return '$ownedUniqueSlots';
    return '$ownedUniqueSlots/$total';
  }
}

class CollectionStore extends ChangeNotifier {
  final List<CollectionEntry> _entries = [];

  List<CollectionEntry> get items => List.unmodifiable(_entries);
  int get count => _entries.length;

  bool containsCardId(String id) => _entries.any((e) => e.card.id == id);

  double get totalEstimatedValue {
    double sum = 0;
    for (final item in _entries) {
      final v = item.estimatedMid ?? item.marketAtSave ?? item.card.bestMarket;
      if (v != null) sum += v;
    }
    return sum;
  }

  double get totalMarketValue {
    double sum = 0;
    for (final item in _entries) {
      final m = item.marketAtSave ?? item.card.bestMarket;
      if (m != null) sum += m;
    }
    return sum;
  }

  // ---------------- Add / remove ----------------

  void addCardWithSnapshot({
    required PokemonCardResult card,
    required int userGrade,
    String? localPhotoPath,
    String? finish,
    double? market,
    double? high,
    double? estLow,
    double? estHigh,
  }) {
    final entry = CollectionEntry(
      entryId: _newEntryId(),
      card: card,
      addedAt: DateTime.now(),
      userGrade: userGrade,
      finish: finish,
      localPhotoPath: localPhotoPath,
      marketAtSave: market,
      highAtSave: high,
      estLowAtSave: estLow,
      estHighAtSave: estHigh,
    );
    _entries.insert(0, entry);
    notifyListeners();
  }

  void addCard(PokemonCardResult card, {String? localPhotoPath}) {
    final entry = CollectionEntry(
      entryId: _newEntryId(),
      card: card,
      addedAt: DateTime.now(),
      userGrade: 8,
      localPhotoPath: localPhotoPath,
    );
    _entries.insert(0, entry);
    notifyListeners();
  }

  void removeCardById(String id) {
    _entries.removeWhere((e) => e.card.id == id);
    notifyListeners();
  }

  void removeEntryByEntryId(String entryId) {
    _entries.removeWhere((e) => e.entryId == entryId);
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// Dev helper: lets you see the Collection UI without scanning.
  /// Call once on app start. Only seeds if empty.
  void seedDemoIfEmpty() {
    if (_entries.isNotEmpty) return;

    final demoCard = PokemonCardResult(
      id: 'demo-card-1',
      name: 'Demo Card',
      setName: 'Demo Set',
      setId: 'demo-set',
      number: '1',
      setPrintedTotal: 94,

      // Images can be any valid https image. Use a tiny placeholder.
      imageSmall: 'https://via.placeholder.com/200x280.png?text=Demo',
      imageLarge: 'https://via.placeholder.com/600x840.png?text=Demo',

      // finishes is required by your model
      finishes: const <String, PriceRow>{},

      // Optional
      tcgplayerUrl: null,
      hp: null,
      supertype: 'Pokémon',
      subtypes: const [],
    );

    addCard(demoCard);
  }

  // ---------------- main.dart expects these ----------------

  List<CollectionEntry> itemsForSet(String setKey) {
    return _entries.where((e) => e.card.setId == setKey).toList();
  }

  List<SetSummary> getSetSummaries() {
    final Map<String, List<CollectionEntry>> bySet = {};

    for (final e in _entries) {
      final sid = e.card.setId.trim();
      if (sid.isEmpty) continue;
      (bySet[sid] ??= <CollectionEntry>[]).add(e);
    }

    final summaries = <SetSummary>[];

    bySet.forEach((setId, list) {
      final setName = list.first.card.setName;
      final ownedInstances = list.length;
      final ownedUniqueSlots = list.map((e) => e.card.id).toSet().length;

      int? printedTotal;
      for (final e in list) {
        final pt = e.card.setPrintedTotal;
        if (pt != null && pt > 0) {
          printedTotal = pt;
          break;
        }
      }

      summaries.add(
        SetSummary(
          setKey: setId,
          setName: setName,
          ownedInstances: ownedInstances,
          ownedUniqueSlots: ownedUniqueSlots,
          printedTotal: printedTotal,
        ),
      );
    });

    // sort by newest activity in the set
    summaries.sort((a, b) {
      final aNewest = bySet[a.setKey]!
          .map((e) => e.addedAt)
          .reduce((x, y) => x.isAfter(y) ? x : y);
      final bNewest = bySet[b.setKey]!
          .map((e) => e.addedAt)
          .reduce((x, y) => x.isAfter(y) ? x : y);
      return bNewest.compareTo(aNewest);
    });

    return summaries;
  }

  Map<int, PokemonCardResult> getOwnedSlotMapForSet(String setKey) {
    final entries = itemsForSet(setKey);
    final out = <int, PokemonCardResult>{};

    for (final e in entries) {
      final digits = e.card.number.replaceAll(RegExp(r'[^0-9]'), '');
      final n = int.tryParse(digits);
      if (n == null) continue;

      // newest wins (entries are newest-first anyway)
      out[n] = e.card;
    }

    return out;
  }

  int registeredCountForSet(String setKey) {
    final entries = itemsForSet(setKey);
    return entries.map((e) => e.card.id).toSet().length;
  }

  /// Step 2: slotNumber -> PreviewCard (name + image urls)
  /// Returns empty until ensureSetIndexLoaded() has been called for that set.
  Map<int, PreviewCard> getPreviewSlotMapForSet(String setKey) {
    final map = _setIndex[setKey];
    if (map == null || map.isEmpty) return <int, PreviewCard>{};

    final out = <int, PreviewCard>{};
    map.forEach((slot, card) {
      out[slot] = card.toPreview();
    });
    return out;
  }

  // ---------------- Step 2 Preview Index ----------------
  //
  // Goal: when you tap a missing slot (e.g. #007), you can show a preview
  // image (later we’ll grayscale it) + locked details + scan button.
  //
  // For now: this returns cached preview info if index was loaded.
  // Next step will be wiring ensureSetIndexLoaded() from your set screen.

  final Map<String, Map<int, PokemonCardResult>> _setIndex = {};
  final Set<String> _loadingSetIndex = {};

  bool hasSetIndex(String setKey) => _setIndex.containsKey(setKey);

  Future<void> ensureSetIndexLoaded({
    required String setKey,
    required String setId,
  }) async {
    if (_setIndex.containsKey(setKey) || _loadingSetIndex.contains(setKey)) {
      // ignore: avoid_print
      print(
        '🧩 ensureSetIndexLoaded SKIP → already loaded/loading (setKey=$setKey)',
      );
      return;
    }

    _loadingSetIndex.add(setKey);
    // ignore: avoid_print
    print('🧩 ensureSetIndexLoaded START → setKey=$setKey setId=$setId');

    try {
      if (setId.trim().isEmpty) {
        // ignore: avoid_print
        print('🧩 ensureSetIndexLoaded ABORT → empty setId');
        _setIndex[setKey] = {};
        return;
      }

      final api = PokemonTcgApi();

      // ignore: avoid_print
      print('🧩 fetching set index from API… (setId=$setId)');
      final cards = await api.fetchAllCardsForSet(setId);
      // ignore: avoid_print
      print('🧩 fetched ${cards.length} cards for setId=$setId');

      final map = <int, PokemonCardResult>{};
      var skippedNonNumeric = 0;

      for (final c in cards) {
        final digits = c.number.replaceAll(RegExp(r'[^0-9]'), '');
        final n = int.tryParse(digits);
        if (n == null) {
          skippedNonNumeric++;
          continue;
        }
        map.putIfAbsent(n, () => c);
      }

      _setIndex[setKey] = map;

      // ignore: avoid_print
      print(
        '🧩 index READY → slotsIndexed=${map.length} skippedNonNumeric=$skippedNonNumeric (setKey=$setKey)',
      );

      notifyListeners();
    } catch (e, st) {
      // ignore: avoid_print
      print('❌ ensureSetIndexLoaded FAILED → $e');
      // ignore: avoid_print
      print(st);

      // still set empty so UI stops saying “preview not loaded yet”
      _setIndex[setKey] = {};
      notifyListeners();
    } finally {
      _loadingSetIndex.remove(setKey);
      // ignore: avoid_print
      print('🧩 ensureSetIndexLoaded END → setKey=$setKey');
    }
  }

  // ---------------- Private helpers ----------------

  String _newEntryId() {
    final micros = DateTime.now().microsecondsSinceEpoch;
    final salt = _entries.length;
    return 'e_${micros}_$salt';
  }
}

final collectionStore = CollectionStore();
