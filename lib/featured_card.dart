import 'pokemon_models.dart';

class FeaturedCardMeta {
  final String headline;
  final String why;

  const FeaturedCardMeta({required this.headline, required this.why});
}

class FeaturedCardData {
  final PokemonCardResult card;
  final FeaturedCardMeta meta;
  final String ymd;

  const FeaturedCardData({
    required this.card,
    required this.meta,
    required this.ymd,
  });
}

class FeaturedCardService {
  static String _ymd(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static int _dayIndexSince(DateTime anchor) {
    final now = DateTime.now();
    final a = DateTime(anchor.year, anchor.month, anchor.day);
    final b = DateTime(now.year, now.month, now.day);
    return b.difference(a).inDays;
  }

  static final List<FeaturedCardData> _pool = [
    FeaturedCardData(
      ymd: '',
      card: PokemonCardResult(
        id: 'base1-4',
        name: 'Charizard',
        setName: 'Base',
        setId: 'base1',
        number: '4',
        imageSmall: 'https://images.pokemontcg.io/base1/4.png',
        imageLarge: 'https://images.pokemontcg.io/base1/4_hires.png',
        finishes: const <String, PriceRow>{},
        tcgplayerUrl: null,
        setPrintedTotal: 102,
        hp: 120,
        supertype: 'Pokémon',
        subtypes: const <String>['Stage 2'],
      ),
      meta: const FeaturedCardMeta(
        headline: 'Historic grail',
        why:
            'Base Set Charizard helped define Pokémon collecting for an entire generation.',
      ),
    ),
    FeaturedCardData(
      ymd: '',
      card: PokemonCardResult(
        id: 'base1-2',
        name: 'Blastoise',
        setName: 'Base',
        setId: 'base1',
        number: '2',
        imageSmall: 'https://images.pokemontcg.io/base1/2.png',
        imageLarge: 'https://images.pokemontcg.io/base1/2_hires.png',
        finishes: const <String, PriceRow>{},
        tcgplayerUrl: null,
        setPrintedTotal: 102,
        hp: 100,
        supertype: 'Pokémon',
        subtypes: const <String>['Stage 2'],
      ),
      meta: const FeaturedCardMeta(
        headline: 'Original starter trio',
        why:
            'Blastoise is one of the original Base Set powerhouse cards and a huge nostalgia pull.',
      ),
    ),
    FeaturedCardData(
      ymd: '',
      card: PokemonCardResult(
        id: 'base1-15',
        name: 'Venusaur',
        setName: 'Base',
        setId: 'base1',
        number: '15',
        imageSmall: 'https://images.pokemontcg.io/base1/15.png',
        imageLarge: 'https://images.pokemontcg.io/base1/15_hires.png',
        finishes: const <String, PriceRow>{},
        tcgplayerUrl: null,
        setPrintedTotal: 102,
        hp: 100,
        supertype: 'Pokémon',
        subtypes: const <String>['Stage 2'],
      ),
      meta: const FeaturedCardMeta(
        headline: 'Original starter trio',
        why:
            'Venusaur completes the original Base trio and remains a classic collector favorite.',
      ),
    ),
    FeaturedCardData(
      ymd: '',
      card: PokemonCardResult(
        id: 'base1-58',
        name: 'Pikachu',
        setName: 'Base',
        setId: 'base1',
        number: '58',
        imageSmall: 'https://images.pokemontcg.io/base1/58.png',
        imageLarge: 'https://images.pokemontcg.io/base1/58_hires.png',
        finishes: const <String, PriceRow>{},
        tcgplayerUrl: null,
        setPrintedTotal: 102,
        hp: 40,
        supertype: 'Pokémon',
        subtypes: const <String>['Basic'],
      ),
      meta: const FeaturedCardMeta(
        headline: 'Mascot classic',
        why:
            'Pikachu is the face of Pokémon and one of the most recognizable cards in the hobby.',
      ),
    ),
    FeaturedCardData(
      ymd: '',
      card: PokemonCardResult(
        id: 'sv3pt5-183',
        name: 'Charizard ex',
        setName: '151',
        setId: 'sv3pt5',
        number: '183',
        imageSmall: 'https://images.pokemontcg.io/sv3pt5/183.png',
        imageLarge: 'https://images.pokemontcg.io/sv3pt5/183_hires.png',
        finishes: const <String, PriceRow>{},
        tcgplayerUrl: null,
        setPrintedTotal: 165,
        hp: 330,
        supertype: 'Pokémon',
        subtypes: const <String>['Stage 2', 'ex'],
      ),
      meta: const FeaturedCardMeta(
        headline: 'Modern icon',
        why:
            'Even in modern sets, Charizard still drives collector attention like almost nothing else.',
      ),
    ),
  ];

  static Future<FeaturedCardData?> getToday() async {
    if (_pool.isEmpty) return null;

    final i = _dayIndexSince(DateTime(2024, 1, 1));
    final picked = _pool[i % _pool.length];

    return FeaturedCardData(
      ymd: _ymd(DateTime.now()),
      card: picked.card,
      meta: picked.meta,
    );
  }
}
