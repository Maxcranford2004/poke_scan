import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'pokemon_models.dart';
import 'pokemon_tcg_api.dart';
import 'services/firestore_collection_service.dart';

typedef MarketValueQueryBuilder = String Function(PokemonCardResult card);
typedef MarketValueFetcher = Future<double?> Function({required String query});

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

  CollectionEntry copyWith({PokemonCardResult? card, DateTime? addedAt}) {
    return CollectionEntry(
      entryId: entryId,
      card: card ?? this.card,
      addedAt: addedAt ?? this.addedAt,
      userGrade: userGrade,
      finish: finish,
      localPhotoPath: localPhotoPath,
      marketAtSave: marketAtSave,
      highAtSave: highAtSave,
      estLowAtSave: estLowAtSave,
      estHighAtSave: estHighAtSave,
    );
  }

  factory CollectionEntry.fromJson(Map<String, dynamic> json) {
    double? d(dynamic v) => v is num ? v.toDouble() : null;

    return CollectionEntry(
      entryId: (json['entryId'] ?? '').toString(),
      card: PokemonCardResult.fromJson(
        Map<String, dynamic>.from(json['card'] as Map? ?? const {}),
      ),
      addedAt:
          DateTime.tryParse((json['addedAt'] ?? '').toString()) ??
          DateTime.now(),
      userGrade: (json['userGrade'] as int?) ?? 8,
      finish: json['finish']?.toString(),
      localPhotoPath: json['localPhotoPath']?.toString(),
      marketAtSave: d(json['marketAtSave']),
      highAtSave: d(json['highAtSave']),
      estLowAtSave: d(json['estLowAtSave']),
      estHighAtSave: d(json['estHighAtSave']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'entryId': entryId,
      'card': card.toJson(),
      'addedAt': addedAt.toIso8601String(),
      'userGrade': userGrade,
      'finish': finish,
      'localPhotoPath': localPhotoPath,
      'marketAtSave': marketAtSave,
      'highAtSave': highAtSave,
      'estLowAtSave': estLowAtSave,
      'estHighAtSave': estHighAtSave,
    };
  }
}

/// Summary used by your Sets list UI in main.dart.
class SetSummary {
  /// Keep the name main.dart expects.
  final String setKey;
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
  /// Make it NON-null to avoid String? errors.
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

class CollectedEvent {
  final String setKey;
  final int slot;
  final String cardName;
  final String imageUrl;

  CollectedEvent({
    required this.setKey,
    required this.slot,
    required this.cardName,
    required this.imageUrl,
  });
}

/// Step 4 (store-side): a small event object your UI can listen to
/// to show “+XP”, “Level up”, etc.
class XpEvent {
  final int xpGained;
  final int totalXp;
  final int level;
  final bool leveledUp;
  final int streak;
  final bool isNewCard;

  const XpEvent({
    required this.xpGained,
    required this.totalXp,
    required this.level,
    required this.leveledUp,
    required this.streak,
    required this.isNewCard,
  });
}

class AchievementEvent {
  final String id;
  final String title;

  const AchievementEvent({required this.id, required this.title});
}

class PokedexEvent {
  final String cardId;
  final String cardName;
  final String imageUrl;

  const PokedexEvent({
    required this.cardId,
    required this.cardName,
    required this.imageUrl,
  });
}

class CollectionStore extends ChangeNotifier {
  CollectionStore({FirestoreCollectionService? firestoreCollectionService})
    : _firestoreCollectionService =
          firestoreCollectionService ?? firestoreCollectionServiceInstance;

  // ---------------- Owned entries ----------------

  final List<CollectionEntry> _entries = [];
  final FirestoreCollectionService _firestoreCollectionService;
  final ValueNotifier<int> collectionViewVersion = ValueNotifier<int>(0);
  final ValueNotifier<int> profileViewVersion = ValueNotifier<int>(0);
  final ValueNotifier<int> setIndexVersion = ValueNotifier<int>(0);
  int _derivedCollectionCacheVersion = -1;
  List<SetSummary> _cachedSetSummaries = <SetSummary>[];
  Map<String, List<CollectionEntry>> _cachedEntriesBySet =
      <String, List<CollectionEntry>>{};
  Map<String, Map<int, PokemonCardResult>> _cachedOwnedSlotMapsBySet =
      <String, Map<int, PokemonCardResult>>{};
  Map<String, int> _cachedRegisteredCountsBySet = <String, int>{};

  List<CollectionEntry> get items => List.unmodifiable(_entries);
  int get count => _entries.length;
  int get uniqueRegisteredCount =>
      _entries.map((e) => e.card.id).toSet().length;
  int get missingMarketValueCardCount {
    final missingCardIds = <String>{};
    for (final entry in _entries) {
      if (entry.card.marketValue == null) {
        missingCardIds.add(entry.card.id);
      }
    }
    return missingCardIds.length;
  }

  bool get allMarketValuesRefreshed =>
      _entries.isNotEmpty && missingMarketValueCardCount == 0;

  bool containsCardId(String id) => _entries.any((e) => e.card.id == id);

  List<CollectionEntry> recentUniqueItems({int limit = 4}) {
    final seenCardIds = <String>{};
    final uniqueEntries = <CollectionEntry>[];

    for (final entry in _entries) {
      if (!seenCardIds.add(entry.card.id)) continue;
      uniqueEntries.add(entry);
      if (uniqueEntries.length >= limit) break;
    }

    return List.unmodifiable(uniqueEntries);
  }

  double get totalEstimatedValue {
    return totalMarketValue;
  }

  double get totalMarketValue {
    double sum = 0;
    for (final item in _entries) {
      final m = item.card.marketValue;
      if (m != null) sum += m;
    }
    return sum;
  }

  // ---------------- Profile / progression ----------------

  static const String _profileBoxName = 'profile_v1';
  static const String _collectionBoxName = 'collection_v1';
  static const String _collectionEntriesKey = 'entries';
  static const String _unlockedAchievementsKey = 'unlockedAchievements';

  static const String achievementFirstScan = 'first_scan';
  static const String achievementScan10 = 'scan_10';
  static const String achievementScan25 = 'scan_25';
  static const String achievementFirstUnique = 'first_unique';
  static const String achievementUnique10 = 'unique_10';
  static const String achievementStreak3 = 'streak_3';
  static const String achievementFirstDuplicate = 'duplicate_1';
  static const String achievementSetStarted = 'set_started';
  static const String achievementSet25 = 'set_25';
  static const String achievementSet50 = 'set_50';
  static const String achievementSetComplete = 'set_complete';
  static const String achievementStreak7 = 'streak_7';
  static const String achievementHighValue = 'high_value_20';

  int _totalXp = 0;
  int _streak = 0;
  String? _lastScanYmd; // "YYYY-MM-DD"
  int _totalScans = 0;
  final Set<String> _unlockedAchievements = <String>{};
  bool _cloudSyncComplete = false;
  bool _cloudSyncInProgress = false;
  bool _marketValueRefreshInProgress = false;
  bool _persistentCollectionAccessEnabled = false;
  bool _sessionAccessInitialized = false;
  String? _activeUserId;
  int _authGeneration = 0;
  MarketValueQueryBuilder? _marketValueQueryBuilder;
  MarketValueFetcher? _marketValueFetcher;

  int get totalXp => _totalXp;
  int get streak => _streak;
  int get totalScans => _totalScans;
  Set<String> get unlockedAchievements =>
      Set.unmodifiable(_unlockedAchievements);
  bool get cloudSyncComplete => _cloudSyncComplete;
  bool get cloudSyncInProgress => _cloudSyncInProgress;
  bool get marketValueRefreshInProgress => _marketValueRefreshInProgress;
  bool get persistentCollectionAccessEnabled =>
      _persistentCollectionAccessEnabled;

  // Simple leveling curve: 500 XP per level
  int get level => (_totalXp ~/ 500) + 1;
  int get xpIntoLevel => _totalXp % 500;
  double get levelProgress => xpIntoLevel / 500.0;

  /// UI can listen to this to show a “+XP” toast, level-up animation, etc.
  final ValueNotifier<XpEvent?> lastXpEvent = ValueNotifier<XpEvent?>(null);
  final ValueNotifier<AchievementEvent?> lastAchievementEvent =
      ValueNotifier<AchievementEvent?>(null);
  final ValueNotifier<PokedexEvent?> lastPokedexEvent =
      ValueNotifier<PokedexEvent?>(null);

  Future<void> initProfile() async {
    final box = await Hive.openBox(_profileBoxName);
    _totalXp = (box.get(_profileScopedKey('totalXp')) as int?) ?? 0;
    _streak = (box.get(_profileScopedKey('streak')) as int?) ?? 0;
    _lastScanYmd = box.get(_profileScopedKey('lastScanYmd')) as String?;
    _totalScans = (box.get(_profileScopedKey('totalScans')) as int?) ?? 0;
    final rawUnlocked = box.get(_profileScopedKey(_unlockedAchievementsKey));
    _unlockedAchievements
      ..clear()
      ..addAll(
        rawUnlocked is List
            ? rawUnlocked.map((e) => e.toString())
            : const <String>[],
      );

    await _loadCollectionCache();
    await _checkAndUnlockAchievements();
  }

  Future<void> handleAuthUserChanged(User? user) async {
    final oldUid = _activeUserId;
    final newUid = user?.uid;
    final enabled = user != null && !user.isAnonymous;

    debugPrint('COLLECTION AUTH SWITCH >>> oldUid=$oldUid newUid=$newUid');
    debugPrint(
      'AUTH FLOW >>> collection auth change received uid=${newUid ?? ''} enabled=$enabled',
    );

    if (_sessionAccessInitialized &&
        oldUid == newUid &&
        _persistentCollectionAccessEnabled == enabled) {
      debugPrint('AUTH FLOW >>> collection auth change skipped (no-op)');
      return;
    }

    try {
      _sessionAccessInitialized = true;
      _activeUserId = newUid;
      _authGeneration += 1;
      _persistentCollectionAccessEnabled = enabled;

      debugPrint('AUTH FLOW >>> collection reset triggered generation=$_authGeneration');
      _resetActiveState();
      _bumpCollectionViewVersion();
      notifyListeners();

      if (!enabled) {
        debugPrint('AUTH FLOW >>> collection auth change completed without sync');
        return;
      }

      debugPrint('AUTH FLOW >>> collection profile load triggered uid=$newUid');
      await initProfile();
      debugPrint('AUTH FLOW >>> collection sync triggered uid=$newUid');
      unawaited(syncFromFirestore());
      notifyListeners();
    } catch (e, st) {
      debugPrint('AUTH FLOW >>> collection auth change failed: $e');
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<void> setPersistentCollectionAccessEnabled(bool enabled) async {
    if (_sessionAccessInitialized &&
        _persistentCollectionAccessEnabled == enabled) {
      return;
    }

    _sessionAccessInitialized = true;
    _persistentCollectionAccessEnabled = enabled;

    if (!enabled) {
      _applyGuestBlankSlate();
      return;
    }

    _cloudSyncComplete = false;
    _cloudSyncInProgress = false;
    await initProfile();
    unawaited(syncFromFirestore());
    notifyListeners();
  }

  Future<void> _saveProfile() async {
    if (!_persistentCollectionAccessEnabled) return;
    final box = await Hive.openBox(_profileBoxName);
    await box.put(_profileScopedKey('totalXp'), _totalXp);
    await box.put(_profileScopedKey('streak'), _streak);
    await box.put(_profileScopedKey('lastScanYmd'), _lastScanYmd);
    await box.put(_profileScopedKey('totalScans'), _totalScans);
    await box.put(
      _profileScopedKey(_unlockedAchievementsKey),
      _unlockedAchievements.toList(growable: false),
    );
  }

  int get _uniqueCardCount => _entries.map((e) => e.card.id).toSet().length;
  bool get hasDuplicateCard => _buildAchievementMetrics().hasDuplicateCard;
  int get registeredSlotCount => _uniqueCardCount;
  int get startedSetCount => _buildAchievementMetrics().startedSetCount;
  int get completedSetCount => _buildAchievementMetrics().completedSetCount;
  double get bestSetProgress => _buildAchievementMetrics().bestSetProgress;
  bool get hasHighValueCard => _buildAchievementMetrics().hasHighValueCard;

  String _achievementTitle(String id) {
    switch (id) {
      case achievementFirstScan:
        return 'First Card Registered';
      case achievementScan10:
        return '5 Cards Registered';
      case achievementScan25:
        return '25 Cards Registered';
      case achievementFirstUnique:
        return 'First Pokedex Slot Filled';
      case achievementUnique10:
        return '10 Pokedex Slots Filled';
      case achievementFirstDuplicate:
        return 'First Duplicate';
      case achievementSetStarted:
        return 'First Set Started';
      case achievementSet25:
        return 'First Set at 25%';
      case achievementSet50:
        return 'First Set at 50%';
      case achievementSetComplete:
        return 'First Set Completed';
      case achievementStreak3:
        return '3-Day Scan Streak';
      case achievementStreak7:
        return '7-Day Scan Streak';
      case achievementHighValue:
        return 'First \$20+ Card';
      default:
        return 'Achievement Unlocked';
    }
  }

  Future<void> _checkAndUnlockAchievements() async {
    final metrics = _buildAchievementMetrics();
    final unlockOrder = <String>[
      if (_totalScans >= 1) achievementFirstScan,
      if (_totalScans >= 5) achievementScan10,
      if (_totalScans >= 25) achievementScan25,
      if (_uniqueCardCount >= 1) achievementFirstUnique,
      if (_uniqueCardCount >= 10) achievementUnique10,
      if (metrics.hasDuplicateCard) achievementFirstDuplicate,
      if (metrics.startedSetCount >= 1) achievementSetStarted,
      if (metrics.bestSetProgress >= 0.25) achievementSet25,
      if (metrics.bestSetProgress >= 0.50) achievementSet50,
      if (metrics.completedSetCount >= 1) achievementSetComplete,
      if (_streak >= 3) achievementStreak3,
      if (_streak >= 7) achievementStreak7,
      if (metrics.hasHighValueCard) achievementHighValue,
    ];

    final newlyUnlocked = <String>[];
    for (final id in unlockOrder) {
      final added = _unlockedAchievements.add(id);
      if (added) {
        newlyUnlocked.add(id);
      }
    }

    if (newlyUnlocked.isEmpty) return;

    await _saveProfile();
    _bumpProfileViewVersion();

    // Emit each unlock immediately and let the UI queue decide playback timing.
    for (final id in newlyUnlocked) {
      lastAchievementEvent.value = AchievementEvent(
        id: id,
        title: _achievementTitle(id),
      );
    }
  }

  Future<void> _loadCollectionCache() async {
    debugPrint('CollectionStore local collection load started');

    try {
      final box = await Hive.openBox(_collectionBoxName);
      final rawEntries = box.get(_collectionEntriesScopedKey);

      _entries
        ..clear()
        ..addAll(_deserializeCollectionEntries(rawEntries));

      debugPrint(
        'CollectionStore local collection loaded: ${_entries.length} entries',
      );
      _bumpCollectionViewVersion();
    } catch (e, st) {
      debugPrint('CollectionStore local collection load failed: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  Future<void> _saveCollectionCache() async {
    if (!_persistentCollectionAccessEnabled) return;
    try {
      final box = await Hive.openBox(_collectionBoxName);
      final data = _entries.map((e) => e.toJson()).toList(growable: false);
      await box.put(_collectionEntriesScopedKey, data);
    } catch (e, st) {
      debugPrint('CollectionStore local collection save failed: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  String _ymd(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  bool _isYesterday(String a, String b) {
    final ad = DateTime.tryParse(a);
    final bd = DateTime.tryParse(b);
    if (ad == null || bd == null) return false;
    return bd.difference(ad).inDays == 1;
  }

  Future<void> _recordScanForToday() async {
    final today = _ymd(DateTime.now());

    if (_lastScanYmd == null) {
      _streak = 1;
    } else if (_lastScanYmd == today) {
      // already scanned today → keep streak
    } else if (_isYesterday(_lastScanYmd!, today)) {
      _streak += 1;
    } else {
      _streak = 1;
    }

    _lastScanYmd = today;
    _totalScans += 1;

    await _saveProfile();
    _bumpProfileViewVersion();
  }

  int _xpForScan({required bool isNewCard, required int streak}) {
    // Step 3 XP rules:
    // - New card: 25
    // - Duplicate: 5
    // - Streak bonus: +5 if streak >= 2
    final base = isNewCard ? 25 : 5;
    final bonus = (streak >= 2) ? 5 : 0;
    return base + bonus;
  }

  Future<void> _awardXp(int gained, {required bool isNewCard}) async {
    final beforeLevel = level;
    _totalXp += gained;
    await _saveProfile();

    final afterLevel = level;
    final leveledUp = afterLevel > beforeLevel;

    lastXpEvent.value = XpEvent(
      xpGained: gained,
      totalXp: _totalXp,
      level: afterLevel,
      leveledUp: leveledUp,
      streak: _streak,
      isNewCard: isNewCard,
    );
    _bumpProfileViewVersion();
  }

  void _emitPokedexRegistered(PokemonCardResult card) {
    lastPokedexEvent.value = PokedexEvent(
      cardId: card.id,
      cardName: card.name,
      imageUrl: card.imageLarge.isNotEmpty ? card.imageLarge : card.imageSmall,
    );
  }

  Future<void> _handleProgressionForScan({
    required bool isNewCard,
    required PokemonCardResult card,
  }) async {
    // 1) streak + scans
    await _recordScanForToday();

    // 2) achievement unlocks
    await _checkAndUnlockAchievements();

    // 3) Pokedex registration feedback for new cards
    if (isNewCard) {
      _emitPokedexRegistered(card);
    }

    // 4) xp award
    final gained = _xpForScan(isNewCard: isNewCard, streak: _streak);
    await _awardXp(gained, isNewCard: isNewCard);

    // 5) tell UI something changed
    notifyListeners();
  }

  Future<void> syncFromFirestore() async {
    if (!_persistentCollectionAccessEnabled ||
        _cloudSyncInProgress ||
        _cloudSyncComplete) {
      return;
    }

    final syncGeneration = _authGeneration;
    final syncUid = _activeUserId;
    _cloudSyncInProgress = true;
    _bumpProfileViewVersion();
    notifyListeners();
    debugPrint('CollectionStore Firestore fetch started');

    try {
      final remoteCards = await _firestoreCollectionService.fetchOwnedCards();
      if (syncGeneration != _authGeneration || syncUid != _activeUserId) {
        debugPrint('CollectionStore Firestore fetch discarded after auth switch');
        return;
      }
      final mergeResult = _mergeFirestoreRecords(remoteCards);

      if (mergeResult.changed) {
        await _saveCollectionCache();
        _bumpCollectionViewVersion();
        await _checkAndUnlockAchievements();
        notifyListeners();
      }

      debugPrint(
        'CollectionStore Firestore fetch succeeded: '
        'remote=${remoteCards.length}, '
        'cardsMerged=${mergeResult.cardsMerged}, '
        'entriesAdded=${mergeResult.entriesAdded}, '
        'metadataUpdated=${mergeResult.metadataUpdated}',
      );
    } catch (e, st) {
      debugPrint('CollectionStore Firestore fetch failed: $e');
      debugPrintStack(stackTrace: st);
    } finally {
      if (syncGeneration != _authGeneration || syncUid != _activeUserId) {
        return;
      }
      _cloudSyncInProgress = false;
      _cloudSyncComplete = true;
      _bumpProfileViewVersion();
      notifyListeners();
    }
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
    if (!_persistentCollectionAccessEnabled) return;
    final isNewCard = !containsCardId(card.id);

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

    // Keep signature sync; do progression async.
    // ignore: unawaited_futures
    _handleProgressionForScan(isNewCard: isNewCard, card: card);
    _bumpCollectionViewVersion();
    unawaited(_syncCardToFirestore(card));
    unawaited(_saveCollectionCache());

    notifyListeners();
  }

  void addCard(PokemonCardResult card, {String? localPhotoPath}) {
    if (!_persistentCollectionAccessEnabled) return;
    final isNewCard = !containsCardId(card.id);

    final entry = CollectionEntry(
      entryId: _newEntryId(),
      card: card,
      addedAt: DateTime.now(),
      userGrade: 8,
      localPhotoPath: localPhotoPath,
    );

    _entries.insert(0, entry);

    // ignore: unawaited_futures
    _handleProgressionForScan(isNewCard: isNewCard, card: card);
    _bumpCollectionViewVersion();
    unawaited(_syncCardToFirestore(card));
    unawaited(_saveCollectionCache());

    notifyListeners();
  }

  bool updateCardMarketValueIfMissing({
    required String cardId,
    required double marketValue,
  }) {
    if (marketValue <= 0) return false;

    final indexes = <int>[];
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].card.id == cardId) {
        indexes.add(i);
      }
    }

    if (indexes.isEmpty) return false;

    PokemonCardResult? updatedCard;
    var updatedAny = false;
    for (final index in indexes) {
      final current = _entries[index];
      if (current.card.marketValue != null) continue;

      final nextCard = current.card.copyWith(marketValue: marketValue);
      _entries[index] = current.copyWith(card: nextCard);
      updatedCard ??= nextCard;
      updatedAny = true;
    }

    if (!updatedAny || updatedCard == null) return false;

    unawaited(_syncCardToFirestore(updatedCard));
    unawaited(_saveCollectionCache());
    unawaited(_checkAndUnlockAchievements());
    _bumpProfileViewVersion();
    notifyListeners();
    return true;
  }

  void configureMarketValueRefresh({
    required MarketValueQueryBuilder queryBuilder,
    required MarketValueFetcher fetcher,
  }) {
    _marketValueQueryBuilder = queryBuilder;
    _marketValueFetcher = fetcher;
  }

  List<PokemonCardResult> cardsMissingMarketValue({int limit = 5}) {
    if (limit <= 0) return const <PokemonCardResult>[];

    final seenCardIds = <String>{};
    final candidates = <PokemonCardResult>[];

    for (final entry in _entries) {
      final cardId = entry.card.id;
      if (!seenCardIds.add(cardId)) continue;

      final hasAnyMissingValueForCard = _entries.any(
        (e) => e.card.id == cardId && e.card.marketValue == null,
      );
      if (!hasAnyMissingValueForCard) continue;

      candidates.add(entry.card);
      if (candidates.length >= limit) break;
    }

    return List.unmodifiable(candidates);
  }

  Future<int> refreshMissingMarketValues({int limit = 5}) async {
    final queryBuilder = _marketValueQueryBuilder;
    final fetcher = _marketValueFetcher;

    if (_marketValueRefreshInProgress ||
        queryBuilder == null ||
        fetcher == null ||
        limit <= 0) {
      return 0;
    }

    _marketValueRefreshInProgress = true;
    _bumpProfileViewVersion();
    notifyListeners();

    var refreshedCount = 0;

    try {
      final candidates = cardsMissingMarketValue(limit: limit);

      for (final card in candidates) {
        final query = queryBuilder(card).trim();
        if (query.isEmpty) continue;

        final marketValue = await fetcher(query: query);
        if (marketValue == null) continue;

        final updated = updateCardMarketValueIfMissing(
          cardId: card.id,
          marketValue: marketValue,
        );
        if (updated) {
          refreshedCount += 1;
        }
      }

      return refreshedCount;
    } finally {
      _marketValueRefreshInProgress = false;
      _bumpProfileViewVersion();
      notifyListeners();
    }
  }

  void removeCardById(String id) {
    _entries.removeWhere((e) => e.card.id == id);
    _bumpCollectionViewVersion();
    unawaited(_saveCollectionCache());
    notifyListeners();
  }

  void removeEntryByEntryId(String entryId) {
    _entries.removeWhere((e) => e.entryId == entryId);
    _bumpCollectionViewVersion();
    unawaited(_saveCollectionCache());
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    _bumpCollectionViewVersion();
    unawaited(_saveCollectionCache());
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
      imageSmall: 'https://via.placeholder.com/200x280.png?text=Demo',
      imageLarge: 'https://via.placeholder.com/600x840.png?text=Demo',
      finishes: const <String, PriceRow>{},
      tcgplayerUrl: null,
      hp: null,
      supertype: 'Pokémon',
      subtypes: const [],
    );

    addCard(demoCard);
  }

  // ---------------- main.dart expects these ----------------

  List<CollectionEntry> itemsForSet(String setKey) {
    _ensureCollectionDerivedCaches();
    return List<CollectionEntry>.from(
      _cachedEntriesBySet[setKey] ?? const <CollectionEntry>[],
    );
  }

  List<SetSummary> getSetSummaries() {
    _ensureCollectionDerivedCaches();
    return List<SetSummary>.from(_cachedSetSummaries);
  }

  List<SetSummary> getSetSummariesView() {
    _ensureCollectionDerivedCaches();
    return _cachedSetSummaries;
  }

  // Used by your Pokedex registered flow.
  final ValueNotifier<CollectedEvent?> lastCollected =
      ValueNotifier<CollectedEvent?>(null);

  void emitCollected(CollectedEvent e) {
    lastCollected.value = e;
  }

  Map<int, PokemonCardResult> getOwnedSlotMapForSet(String setKey) {
    _ensureCollectionDerivedCaches();
    return Map<int, PokemonCardResult>.from(
      _cachedOwnedSlotMapsBySet[setKey] ?? const <int, PokemonCardResult>{},
    );
  }

  Map<int, PokemonCardResult> ownedSlotMapViewForSet(String setKey) {
    _ensureCollectionDerivedCaches();
    return _cachedOwnedSlotMapsBySet[setKey] ??
        const <int, PokemonCardResult>{};
  }

  int registeredCountForSet(String setKey) {
    _ensureCollectionDerivedCaches();
    return _cachedRegisteredCountsBySet[setKey] ?? 0;
  }

  /// SlotNumber -> PreviewCard (name + image urls)
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

  Map<int, PreviewCard> previewSlotMapViewForSet(String setKey) {
    final map = _setIndex[setKey];
    if (map == null || map.isEmpty) return const <int, PreviewCard>{};

    final out = <int, PreviewCard>{};
    map.forEach((slot, card) {
      out[slot] = card.toPreview();
    });
    return out;
  }

  // ---------------- Step 2 Preview Index ----------------

  final Map<String, Map<int, PokemonCardResult>> _setIndex = {};
  final Set<String> _loadingSetIndex = {};

  bool hasSetIndex(String setKey) => _setIndex.containsKey(setKey);

  Future<void> ensureSetIndexLoaded({
    required String setKey,
    required String setId,
  }) async {
    final totalStopwatch = Stopwatch()..start();
    if (_setIndex.containsKey(setKey) || _loadingSetIndex.contains(setKey)) {
      debugPrint(
        'set-index ensureSetIndexLoaded skip '
        'setKey=$setKey reason=already-loaded-or-loading',
      );
      return;
    }

    _loadingSetIndex.add(setKey);
    debugPrint(
      'set-index ensureSetIndexLoaded start setKey=$setKey setId=$setId',
    );

    try {
      if (setId.trim().isEmpty) {
        debugPrint('set-index ensureSetIndexLoaded abort reason=empty-setId');
        _setIndex[setKey] = {};
        _bumpSetIndexVersion();
        notifyListeners();
        return;
      }

      final api = PokemonTcgApi();
      final fetchStopwatch = Stopwatch()..start();
      final cards = await api.fetchAllCardsForSet(setId);
      fetchStopwatch.stop();

      final map = <int, PokemonCardResult>{};
      var skippedNonNumeric = 0;
      var processed = 0;
      const chunkSize = 100;
      final mapBuildStopwatch = Stopwatch()..start();

      for (final card in cards) {
        processed++;
        final digits = card.number.replaceAll(RegExp(r'[^0-9]'), '');
        final slot = int.tryParse(digits);
        if (slot == null) {
          skippedNonNumeric++;
        } else {
          map.putIfAbsent(slot, () => card);
        }

        if (processed % chunkSize == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      mapBuildStopwatch.stop();

      _setIndex[setKey] = map;
      _bumpSetIndexVersion();
      totalStopwatch.stop();

      debugPrint(
        'set-index ensureSetIndexLoaded ready '
        'setKey=$setKey slotsIndexed=${map.length} skipped=$skippedNonNumeric',
      );
      if (kDebugMode) {
        debugPrint(
          'set-index ensureSetIndexLoaded timing '
          'setKey=$setKey cards=${cards.length} '
          'fetchMs=${fetchStopwatch.elapsedMilliseconds} '
          'mapMs=${mapBuildStopwatch.elapsedMilliseconds} '
          'processed=$processed skipped=$skippedNonNumeric '
          'totalMs=${totalStopwatch.elapsedMilliseconds}',
        );
      }

      notifyListeners();
    } catch (e, st) {
      totalStopwatch.stop();
      debugPrint(
        'set-index ensureSetIndexLoaded failed setKey=$setKey error=$e',
      );
      debugPrintStack(stackTrace: st);
      if (kDebugMode) {
        debugPrint(
          'set-index ensureSetIndexLoaded timing '
          'setKey=$setKey totalMs=${totalStopwatch.elapsedMilliseconds} '
          'result=failed',
        );
      }

      _setIndex[setKey] = {};
      _bumpSetIndexVersion();
      notifyListeners();
    } finally {
      _loadingSetIndex.remove(setKey);
      debugPrint('set-index ensureSetIndexLoaded end setKey=$setKey');
    }
  }

  // ---------------- Private helpers ----------------

  String _newEntryId() {
    final micros = DateTime.now().microsecondsSinceEpoch;
    final salt = _entries.length;
    return 'e_${micros}_$salt';
  }

  void _ensureCollectionDerivedCaches() {
    final currentVersion = collectionViewVersion.value;
    if (_derivedCollectionCacheVersion == currentVersion) return;

    final entriesBySet = <String, List<CollectionEntry>>{};
    final ownedSlotMapsBySet = <String, Map<int, PokemonCardResult>>{};
    final registeredCountsBySet = <String, int>{};
    final newestAddedAtBySet = <String, DateTime>{};
    final summaries = <SetSummary>[];

    for (final entry in _entries) {
      final setId = entry.card.setId.trim();
      if (setId.isEmpty) continue;

      (entriesBySet[setId] ??= <CollectionEntry>[]).add(entry);

      final newest = newestAddedAtBySet[setId];
      if (newest == null || entry.addedAt.isAfter(newest)) {
        newestAddedAtBySet[setId] = entry.addedAt;
      }

      final digits = entry.card.number.replaceAll(RegExp(r'[^0-9]'), '');
      final slot = int.tryParse(digits);
      if (slot != null) {
        (ownedSlotMapsBySet[setId] ??= <int, PokemonCardResult>{})[slot] =
            entry.card;
      }
    }

    entriesBySet.forEach((setId, entries) {
      final uniqueIds = entries.map((e) => e.card.id).toSet();
      final registeredCount = uniqueIds.length;
      registeredCountsBySet[setId] = registeredCount;

      int? printedTotal;
      for (final entry in entries) {
        final pt = entry.card.setPrintedTotal;
        if (pt != null && pt > 0) {
          printedTotal = pt;
          break;
        }
      }

      summaries.add(
        SetSummary(
          setKey: setId,
          setName: entries.first.card.setName,
          ownedInstances: entries.length,
          ownedUniqueSlots: registeredCount,
          printedTotal: printedTotal,
        ),
      );
    });

    summaries.sort((a, b) {
      final aNewest = newestAddedAtBySet[a.setKey];
      final bNewest = newestAddedAtBySet[b.setKey];
      if (aNewest == null && bNewest == null) return 0;
      if (aNewest == null) return 1;
      if (bNewest == null) return -1;
      return bNewest.compareTo(aNewest);
    });

    _cachedEntriesBySet = entriesBySet.map(
      (setId, entries) =>
          MapEntry(setId, List<CollectionEntry>.unmodifiable(entries)),
    );
    _cachedOwnedSlotMapsBySet = ownedSlotMapsBySet.map(
      (setId, slotMap) =>
          MapEntry(setId, Map<int, PokemonCardResult>.unmodifiable(slotMap)),
    );
    _cachedRegisteredCountsBySet = Map<String, int>.unmodifiable(
      registeredCountsBySet,
    );
    _cachedSetSummaries = List<SetSummary>.unmodifiable(summaries);
    _derivedCollectionCacheVersion = currentVersion;
  }

  void _invalidateCollectionDerivedCaches() {
    _derivedCollectionCacheVersion = -1;
    _cachedSetSummaries = <SetSummary>[];
    _cachedEntriesBySet = <String, List<CollectionEntry>>{};
    _cachedOwnedSlotMapsBySet = <String, Map<int, PokemonCardResult>>{};
    _cachedRegisteredCountsBySet = <String, int>{};
  }

  void _bumpCollectionViewVersion() {
    _invalidateCollectionDerivedCaches();
    collectionViewVersion.value = collectionViewVersion.value + 1;
    _bumpProfileViewVersion();
  }

  void _bumpSetIndexVersion() {
    setIndexVersion.value = setIndexVersion.value + 1;
  }

  void _bumpProfileViewVersion() {
    profileViewVersion.value = profileViewVersion.value + 1;
  }

  Future<void> _syncCardToFirestore(PokemonCardResult card) async {
    if (!_persistentCollectionAccessEnabled) return;
    try {
      await _firestoreCollectionService.upsertOwnedCard(card);
    } catch (e, st) {
      debugPrint('Firestore collection sync failed for ${card.id}: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  List<CollectionEntry> _deserializeCollectionEntries(dynamic rawEntries) {
    if (rawEntries is! List) return const <CollectionEntry>[];

    final entries = <CollectionEntry>[];
    for (final raw in rawEntries) {
      if (raw is Map) {
        try {
          entries.add(CollectionEntry.fromJson(Map<String, dynamic>.from(raw)));
        } catch (e, st) {
          debugPrint('CollectionStore skipped bad cached entry: $e');
          debugPrintStack(stackTrace: st);
        }
      }
    }
    return entries;
  }

  _FirestoreMergeResult _mergeFirestoreRecords(
    List<FirestoreOwnedCardRecord> remoteCards,
  ) {
    var cardsMerged = 0;
    var entriesAdded = 0;
    var metadataUpdated = 0;
    var changed = false;

    for (final record in remoteCards) {
      if (!record.owned || record.quantity <= 0) continue;

      final indexes = <int>[];
      for (var i = 0; i < _entries.length; i++) {
        if (_entries[i].card.id == record.card.id) {
          indexes.add(i);
        }
      }

      final localCount = indexes.length;
      final mergedCard = _mergeCardMetadata(
        localCount > 0 ? _entries[indexes.first].card : null,
        record.card,
      );

      var touched = false;
      for (final index in indexes) {
        final current = _entries[index];
        if (!_cardsEqual(current.card, mergedCard)) {
          _entries[index] = current.copyWith(card: mergedCard);
          metadataUpdated += 1;
          changed = true;
          touched = true;
        }
      }

      final missingEntries = record.quantity > localCount
          ? record.quantity - localCount
          : 0;

      for (var i = 0; i < missingEntries; i++) {
        _entries.add(
          CollectionEntry(
            entryId: _newEntryId(),
            card: mergedCard,
            addedAt:
                record.dateAdded?.add(Duration(microseconds: i)) ??
                DateTime.now().add(Duration(microseconds: i)),
            userGrade: 8,
          ),
        );
        entriesAdded += 1;
        changed = true;
        touched = true;
      }

      if (touched || localCount > 0) {
        cardsMerged += 1;
      }
    }

    if (changed) {
      _entries.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }

    return _FirestoreMergeResult(
      cardsMerged: cardsMerged,
      entriesAdded: entriesAdded,
      metadataUpdated: metadataUpdated,
      changed: changed,
    );
  }

  _AchievementMetrics _buildAchievementMetrics() {
    final seenCardIds = <String>{};
    var hasDuplicateCard = false;
    var hasHighValueCard = false;
    final setSlotCounts = <String, Set<String>>{};
    final printedTotals = <String, int>{};

    for (final entry in _entries) {
      final cardId = entry.card.id;
      if (!seenCardIds.add(cardId)) {
        hasDuplicateCard = true;
      }

      final marketValue = entry.card.marketValue ?? entry.marketAtSave;
      if (marketValue != null && marketValue >= 20) {
        hasHighValueCard = true;
      }

      final setId = entry.card.setId.trim();
      if (setId.isEmpty) continue;

      (setSlotCounts[setId] ??= <String>{}).add(cardId);
      final printedTotal = entry.card.setPrintedTotal;
      if (printedTotal != null && printedTotal > 0) {
        printedTotals.putIfAbsent(setId, () => printedTotal);
      }
    }

    var bestSetProgress = 0.0;
    var completedSetCount = 0;
    for (final entry in setSlotCounts.entries) {
      final printedTotal = printedTotals[entry.key];
      if (printedTotal == null || printedTotal <= 0) continue;

      final progress = entry.value.length / printedTotal;
      if (progress > bestSetProgress) {
        bestSetProgress = progress;
      }
      if (entry.value.length >= printedTotal) {
        completedSetCount += 1;
      }
    }

    return _AchievementMetrics(
      hasDuplicateCard: hasDuplicateCard,
      startedSetCount: setSlotCounts.length,
      completedSetCount: completedSetCount,
      bestSetProgress: bestSetProgress,
      hasHighValueCard: hasHighValueCard,
    );
  }

  String _profileScopedKey(String key) {
    final uid = _activeUserId?.trim();
    if (uid == null || uid.isEmpty) return key;
    return '$key|$uid';
  }

  String get _collectionEntriesScopedKey {
    final uid = _activeUserId?.trim();
    if (uid == null || uid.isEmpty) return _collectionEntriesKey;
    return '$_collectionEntriesKey|$uid';
  }

  void _resetActiveState() {
    _entries.clear();
    _totalXp = 0;
    _streak = 0;
    _lastScanYmd = null;
    _totalScans = 0;
    _unlockedAchievements.clear();
    _cloudSyncComplete = false;
    _cloudSyncInProgress = false;
    _marketValueRefreshInProgress = false;
    lastXpEvent.value = null;
    lastAchievementEvent.value = null;
    lastPokedexEvent.value = null;
    lastCollected.value = null;
    _invalidateCollectionDerivedCaches();
  }

  void _applyGuestBlankSlate() {
    _resetActiveState();
    _bumpCollectionViewVersion();
    notifyListeners();
  }

  PokemonCardResult _mergeCardMetadata(
    PokemonCardResult? local,
    PokemonCardResult remote,
  ) {
    if (local == null) return remote;

    return PokemonCardResult(
      id: _preferString(local.id, remote.id),
      name: _preferString(local.name, remote.name),
      setName: _preferString(local.setName, remote.setName),
      setId: _preferString(local.setId, remote.setId),
      number: _preferString(local.number, remote.number),
      imageSmall: _preferString(local.imageSmall, remote.imageSmall),
      imageLarge: _preferString(local.imageLarge, remote.imageLarge),
      finishes: local.finishes.isNotEmpty ? local.finishes : remote.finishes,
      tcgplayerUrl: _preferNullableString(
        local.tcgplayerUrl,
        remote.tcgplayerUrl,
      ),
      setPrintedTotal: local.setPrintedTotal ?? remote.setPrintedTotal,
      hp: local.hp ?? remote.hp,
      rarity: _preferNullableString(local.rarity, remote.rarity),
      supertype: _preferNullableString(local.supertype, remote.supertype),
      subtypes: local.subtypes.isNotEmpty ? local.subtypes : remote.subtypes,
    );
  }

  String _preferString(String primary, String fallback) {
    if (primary.trim().isNotEmpty) return primary;
    return fallback;
  }

  String? _preferNullableString(String? primary, String? fallback) {
    if (primary != null && primary.trim().isNotEmpty) return primary;
    if (fallback != null && fallback.trim().isNotEmpty) return fallback;
    return null;
  }

  bool _cardsEqual(PokemonCardResult a, PokemonCardResult b) {
    return a.toJson().toString() == b.toJson().toString();
  }
}

final collectionStore = CollectionStore();

class _AchievementMetrics {
  final bool hasDuplicateCard;
  final int startedSetCount;
  final int completedSetCount;
  final double bestSetProgress;
  final bool hasHighValueCard;

  const _AchievementMetrics({
    required this.hasDuplicateCard,
    required this.startedSetCount,
    required this.completedSetCount,
    required this.bestSetProgress,
    required this.hasHighValueCard,
  });
}

class _FirestoreMergeResult {
  final int cardsMerged;
  final int entriesAdded;
  final int metadataUpdated;
  final bool changed;

  const _FirestoreMergeResult({
    required this.cardsMerged,
    required this.entriesAdded,
    required this.metadataUpdated,
    required this.changed,
  });
}
