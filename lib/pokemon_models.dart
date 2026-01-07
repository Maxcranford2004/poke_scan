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
  final String setName;
  final String number;
  final String imageSmall;
  final String imageLarge;
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
  });

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

    return PokemonCardResult(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      setName: (json['setName'] ?? '').toString(),
      number: (json['number'] ?? '').toString(),
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
      'number': number,
      'imageSmall': imageSmall,
      'imageLarge': imageLarge,
      'tcgplayerUrl': tcgplayerUrl,
      'finishes': finishes.map(
        (k, v) => MapEntry(k, {
          'market': v.market,
          'low': v.low,
          'mid': v.mid,
          'high': v.high,
        }),
      ),
    };
  }
}
