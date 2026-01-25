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

class PokemonCardResult {
  final String id;
  final String name;

  // Set info
  final String setName;
  final String? setId;
  final int? setPrintedTotal; // denominator on the card set (e.g. "/202")

  // Collector number (left side on the card: "65", "TG05", "SWSH020", etc.)
  final String number;

  // Extra disambiguators (helpful when name+number collide)
  final int? hp;
  final String? supertype; // usually "Pokémon"
  final List<String>
  subtypes; // e.g. ["Basic"], ["Stage 1"], ["ex"], ["VSTAR"], etc.

  // Images
  final String imageSmall;
  final String imageLarge;

  // Pricing/link
  final String? tcgplayerUrl;

  /// finish -> prices (normal, holofoil, reverseHolofoil, etc.)
  final Map<String, PriceRow> finishes;

  PokemonCardResult({
    required this.id,
    required this.name,
    required this.setName,
    required this.number,
    required this.imageSmall,
    required this.imageLarge,
    required this.finishes,
    this.tcgplayerUrl,
    this.setId,
    this.setPrintedTotal,
    this.hp,
    this.supertype,
    List<String>? subtypes,
  }) : subtypes = subtypes ?? const [];

  /// convenience: pick a “best” market price to show in search list
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

  factory PokemonCardResult.fromJson(Map<String, dynamic> json) {
    final finishesRaw = json['finishes'];
    final finishes = <String, PriceRow>{};

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

    int? i(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      return int.tryParse(v.toString());
    }

    List<String> listString(dynamic v) {
      if (v is List) return v.map((e) => e.toString()).toList();
      return const [];
    }

    return PokemonCardResult(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      setName: (json['setName'] ?? '').toString(),
      setId: json['setId']?.toString(),
      setPrintedTotal: i(json['setPrintedTotal']),
      number: (json['number'] ?? '').toString(),
      hp: i(json['hp']),
      supertype: json['supertype']?.toString(),
      subtypes: listString(json['subtypes']),
      imageSmall: (json['imageSmall'] ?? '').toString(),
      imageLarge: (json['imageLarge'] ?? '').toString(),
      tcgplayerUrl: json['tcgplayerUrl']?.toString(),
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
      'supertype': supertype,
      'subtypes': subtypes,
      'imageSmall': imageSmall,
      'imageLarge': imageLarge,
      'tcgplayerUrl': tcgplayerUrl,
      'finishes': finishes.map((k, v) => MapEntry(k, v.toJson())),
    };
  }
}
