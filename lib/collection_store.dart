import 'package:flutter/foundation.dart';
import 'pokemon_models.dart';

class CollectionItem {
  final PokemonCardResult card;
  final DateTime addedAt;

  // What the user chose on details screen
  final int userGrade; // 1..10
  final String? finish; // e.g. normal, holofoil, reverseHolofoil
  final String? localPhotoPath; // user scan photo stored locally (optional)

  // Pricing snapshot at time of save
  final double? marketAtSave;
  final double? highAtSave;
  final double? estLowAtSave;
  final double? estHighAtSave;

  CollectionItem({
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

class CollectionStore extends ChangeNotifier {
  final List<CollectionItem> _items = [];

  List<CollectionItem> get items => List.unmodifiable(_items);
  int get count => _items.length;

  bool containsCardId(String id) => _items.any((e) => e.card.id == id);

  /// Primary total shown to user (uses saved estimate if available; otherwise market).
  double get totalEstimatedValue {
    double sum = 0;
    for (final item in _items) {
      final v = item.estimatedMid ?? item.marketAtSave ?? item.card.bestMarket;
      if (v != null) sum += v;
    }
    return sum;
  }

  /// Optional: if you still want raw market total (independent of grade)
  double get totalMarketValue {
    double sum = 0;
    for (final item in _items) {
      final m = item.marketAtSave ?? item.card.bestMarket;
      if (m != null) sum += m;
    }
    return sum;
  }

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
    if (containsCardId(card.id)) return;
    _items.insert(
      0,
      CollectionItem(
        card: card,
        addedAt: DateTime.now(),
        userGrade: userGrade,
        finish: finish,
        localPhotoPath: localPhotoPath,
        marketAtSave: market,
        highAtSave: high,
        estLowAtSave: estLow,
        estHighAtSave: estHigh,
      ),
    );
    notifyListeners();
  }

  // Keep the old method for places you haven't updated yet
  void addCard(PokemonCardResult card, {String? localPhotoPath}) {
    if (containsCardId(card.id)) return;
    _items.insert(
      0,
      CollectionItem(
        card: card,
        addedAt: DateTime.now(),
        localPhotoPath: localPhotoPath,
      ),
    );
    notifyListeners();
  }

  void removeCardById(String id) {
    _items.removeWhere((e) => e.card.id == id);
    notifyListeners();
  }

  void clear() {
    _items.clear();
    notifyListeners();
  }
}

final collectionStore = CollectionStore();
