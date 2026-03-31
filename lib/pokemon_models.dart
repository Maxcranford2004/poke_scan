// lib/pokemon_models.dart

class PriceRow {
  final double? market;
  final double? low;
  final double? mid;
  final double? high;

  PriceRow({this.market, this.low, this.mid, this.high});

  factory PriceRow.fromJson(Map<String, dynamic> json) {
    double? d(dynamic v) => v is num ? v.toDouble() : null;
    return PriceRow(
      market: d(json['market']),
      low: d(json['low']),
      mid: d(json['mid']),
      high: d(json['high']),
    );
  }

  Map<String, dynamic> toJson() => {
    'market': market,
    'low': low,
    'mid': mid,
    'high': high,
  };
}

/// Used for the “blank slot -> preview” UX (Step 2).
/// This is intentionally lightweight so it’s fast to cache.
class PreviewCard {
  final String id; // ✅ add this
  final String name;
  final String imageSmall;
  final String imageLarge;

  const PreviewCard({
    required this.id, // ✅ add this
    required this.name,
    required this.imageSmall,
    required this.imageLarge,
  });
}

extension PokemonCardResultPreview on PokemonCardResult {
  PreviewCard toPreview() {
    return PreviewCard(
      id: id, // ✅ now valid
      name: name,
      imageSmall: imageSmall,
      imageLarge: imageLarge,
    );
  }
}

enum CardHitType {
  normal,
  holo,
  ultra,
  illustration,
  secret,
  promo,
}

CardHitType classifyCard(PokemonCardResult card) {
  final rarity = (card.rarity ?? '').toLowerCase().trim();
  final numberDigits = card.number.replaceAll(RegExp(r'[^0-9]'), '');
  final number = numberDigits.isEmpty ? null : int.tryParse(numberDigits);
  final total = card.setPrintedTotal;
  final setId = card.setId.toLowerCase();
  final cardNumber = card.number.toLowerCase();

  // PROMO
  if (setId.contains('promo') || cardNumber.contains('svp')) {
    return CardHitType.promo;
  }

  // SECRET TIER (MOST IMPORTANT RULE)
  // Any card beyond set size is a "hit"
  if (number != null && total != null && number > total) {
    // Distinguish illustration vs generic secret
    if (rarity.contains('illustration')) {
      return CardHitType.illustration;
    }
    return CardHitType.secret;
  }

  // ILLUSTRATION (non-secret cases, safety fallback)
  if (rarity.contains('special illustration rare') ||
      rarity.contains('illustration rare')) {
    return CardHitType.illustration;
  }

  // ULTRA (modern EX / GX / V full arts typically fall here)
  if (rarity.contains('ultra rare')) {
    return CardHitType.ultra;
  }

  // HOLO / REVERSE HOLO
  if (rarity.contains('holo')) {
    return CardHitType.holo;
  }

  return CardHitType.normal;
}

class PokemonCardResult {
  final String id;
  final String name;

  // Set info
  final String setName;
  final String setId; // make non-null so main.dart stops complaining
  final int? setPrintedTotal;

  // Collector number ("65", "TG05", "SWSH127", etc.)
  final String number;

  // Disambiguators
  final int? hp;
  final String? rarity;
  final String? supertype;
  final List<String> subtypes;

  // Images
  final String imageSmall;
  final String imageLarge;

  // Pricing/link
  final double? marketValue;
  final String? tcgplayerUrl;
  final Map<String, PriceRow> finishes;

  PokemonCardResult({
    required this.id,
    required this.name,
    required this.setName,
    required this.setId,
    required this.number,
    required this.imageSmall,
    required this.imageLarge,
    required this.finishes,
    this.marketValue,
    this.tcgplayerUrl,
    this.setPrintedTotal,
    this.hp,
    this.rarity,
    this.supertype,
    List<String>? subtypes,
  }) : subtypes = subtypes ?? const [];

  PreviewCard toPreview() => PreviewCard(
    id: id,
    name: name,
    imageSmall: imageSmall,
    imageLarge: imageLarge,
  );

  PokemonCardResult copyWith({double? marketValue}) {
    return PokemonCardResult(
      id: id,
      name: name,
      setName: setName,
      setId: setId,
      setPrintedTotal: setPrintedTotal,
      number: number,
      hp: hp,
      rarity: rarity,
      supertype: supertype,
      subtypes: subtypes,
      imageSmall: imageSmall,
      imageLarge: imageLarge,
      marketValue: marketValue ?? this.marketValue,
      tcgplayerUrl: tcgplayerUrl,
      finishes: finishes,
    );
  }

  double? get bestMarket {
    const preferred = [
      'normal',
      'holofoil',
      'reverseHolofoil',
      '1stEditionHolofoil',
      '1stEditionNormal',
    ];

    for (final k in preferred) {
      final p = finishes[k];
      if (p?.market != null) return p!.market;
    }

    for (final p in finishes.values) {
      if (p.market != null) return p.market;
    }
    return null;
  }

  bool get isBasic => subtypes.any((s) => s.toLowerCase() == 'basic');
  bool get isStage1 =>
      subtypes.any((s) => s.toLowerCase().replaceAll(' ', '') == 'stage1');
  bool get isStage2 =>
      subtypes.any((s) => s.toLowerCase().replaceAll(' ', '') == 'stage2');
  CardHitType get hitType => classifyCard(this);

  factory PokemonCardResult.fromJson(Map<String, dynamic> json) {
    int? i(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      return int.tryParse(v.toString());
    }

    double? d(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    List<String> listString(dynamic v) {
      if (v is List) return v.map((e) => e.toString()).toList();
      return const [];
    }

    // finishes/prices: flattened OR raw API format
    final finishes = <String, PriceRow>{};

    final finishesRaw = json['finishes'];
    if (finishesRaw is Map) {
      for (final entry in finishesRaw.entries) {
        final k = entry.key?.toString() ?? '';
        final v = entry.value;
        if (k.isEmpty) continue;
        if (v is Map<String, dynamic>) {
          finishes[k] = PriceRow.fromJson(v);
        } else if (v is Map) {
          finishes[k] = PriceRow.fromJson(Map<String, dynamic>.from(v));
        }
      }
    }

    final tcg = json['tcgplayer'];
    final tcgPrices = (tcg is Map) ? tcg['prices'] : null;
    if (finishes.isEmpty && tcgPrices is Map) {
      for (final entry in tcgPrices.entries) {
        final k = entry.key?.toString() ?? '';
        final v = entry.value;
        if (k.isEmpty) continue;
        if (v is Map<String, dynamic>) {
          finishes[k] = PriceRow.fromJson(v);
        } else if (v is Map) {
          finishes[k] = PriceRow.fromJson(Map<String, dynamic>.from(v));
        }
      }
    }

    final setJson = (json['set'] as Map<String, dynamic>?) ?? const {};
    final printedTotalRaw = setJson['printedTotal'];

    // set info: flattened OR nested
    String setName = (json['setName'] ?? json['set_name'] ?? '').toString();
    String setId = (json['setId'] ?? json['set_id'] ?? '').toString();
    int? setPrintedTotal = printedTotalRaw is int
        ? printedTotalRaw
        : int.tryParse(printedTotalRaw?.toString() ?? '');
    setPrintedTotal ??= i(json['setPrintedTotal'] ?? json['printed_total']);

    final setObj = json['set'];
    if (setObj is Map) {
      if (setName.isEmpty) setName = (setObj['name'] ?? '').toString();
      if (setId.isEmpty) setId = (setObj['id'] ?? '').toString();
      setPrintedTotal ??= i(setObj['printedTotal']);
    }

    // images: flattened OR nested
    String imageSmall = (json['imageSmall'] ?? json['image_small'] ?? '')
        .toString();
    String imageLarge = (json['imageLarge'] ?? json['image_large'] ?? '')
        .toString();

    final imagesObj = json['images'];
    if (imagesObj is Map) {
      if (imageSmall.isEmpty)
        imageSmall = (imagesObj['small'] ?? '').toString();
      if (imageLarge.isEmpty)
        imageLarge = (imagesObj['large'] ?? '').toString();
    }

    // tcgplayer url: flattened OR nested
    String? tcgplayerUrl = json['tcgplayerUrl']?.toString();
    if (tcgplayerUrl == null && tcg is Map) {
      tcgplayerUrl = tcg['url']?.toString();
    }

    return PokemonCardResult(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      setName: setName,
      setId: setId,
      setPrintedTotal: printedTotalRaw is int
          ? printedTotalRaw
          : int.tryParse(printedTotalRaw?.toString() ?? '') ??
                setPrintedTotal,
      number: (json['number'] ?? '').toString(),
      hp: i(json['hp']),
      rarity: json['rarity']?.toString(),
      supertype: json['supertype']?.toString(),
      subtypes: listString(json['subtypes']),
      imageSmall: imageSmall,
      imageLarge: imageLarge,
      marketValue: d(json['marketValue']),
      tcgplayerUrl: tcgplayerUrl,
      finishes: finishes,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'setName': setName,
      'setId': setId,
      'setPrintedTotal': setPrintedTotal,
      'number': number,
      'hp': hp,
      'rarity': rarity,
      'supertype': supertype,
      'subtypes': subtypes,
      'imageSmall': imageSmall,
      'imageLarge': imageLarge,
      'marketValue': marketValue,
      'tcgplayerUrl': tcgplayerUrl,
      'finishes': finishes.map((k, v) => MapEntry(k, v.toJson())),
    };
  }
}
