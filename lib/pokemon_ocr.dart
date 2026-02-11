import 'dart:math';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class OcrGuess {
  final String? name;
  final String? number; // numerator only, e.g. "65"
  final String? setTotal; // denominator, e.g. "202"
  final int? hp;
  final String? stage; // "Basic", "Stage 1", "Stage 2"
  final String rawText;

  // Optional fields
  final String? illustrator;
  final String? regulationMark;
  final int? copyrightYear;

  OcrGuess({
    required this.name,
    required this.number,
    required this.setTotal,
    required this.hp,
    required this.stage,
    required this.rawText,
    this.illustrator,
    this.regulationMark,
    this.copyrightYear,
  });
}

class PokemonOcr {
  static const bool debug = false;

  static final _stopWords = <String>{
    'basic',
    'bsic',
    'asic',
    'sic',
    'stage',
    'trainer',
    'energy',
    'supporter',
    'item',
    'weakness',
    'resistance',
    'retreat',
    'hp',
    'pokemon',
    'pokmon',
    'ability',
    'attack',
    'damage',
    'illustration',
    'illus',
    'artist',
    'mouse',
    'no',
    'ht',
    'wt',
    'lbs',
    'level',
    'lv',
    'evolves',
    'from',
    'rule',
    'box',
  };

  // ---------- Text normalization ----------
  static String _deaccent(String s) {
    return s
        .replaceAll('’', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('é', 'e')
        .replaceAll('É', 'E')
        .replaceAll('á', 'a')
        .replaceAll('Á', 'A')
        .replaceAll('í', 'i')
        .replaceAll('Í', 'I')
        .replaceAll('ó', 'o')
        .replaceAll('Ó', 'O')
        .replaceAll('ú', 'u')
        .replaceAll('Ú', 'U')
        .replaceAll('ñ', 'n')
        .replaceAll('Ñ', 'N');
  }

  static String _squashSpacesLower(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  static String _cleanLineLetters(String s) {
    final normalized = _deaccent(s).trim();
    final cleaned = normalized.replaceAll(RegExp(r"[^A-Za-z\s\-']"), '').trim();
    return cleaned.replaceAll(RegExp(r'\s+'), ' ');
  }

  // ---------- Junk / boilerplate detection ----------
  static bool _looksLikeNonNameLine(String cleanedLower) {
    final t = cleanedLower.trim();
    if (t.isEmpty) return true;

    if (t.startsWith('stage') || t.startsWith('basic')) return true;
    if (t == 'stageb' || t == 'stage' || t == 'basic') return true;

    const badContains = [
      'weakness',
      'resistance',
      'retreat',
      'ability',
      'damage',
      'illus',
      'illustrator',
      'trainer',
      'energy',
      'supporter',
      'item',
      'rule box',
      'rules box',
      'evolves',
    ];
    if (badContains.any(t.contains)) return true;

    final hasStats = t.contains('ht') || t.contains('wt') || t.contains('lbs');
    final hasPokemonWord = t.contains('pokemon') || t.contains('pokmon');
    final startsWithNo =
        t.startsWith('no ') || t.startsWith('no.') || t == 'no';

    if (hasStats && (hasPokemonWord || startsWithNo)) return true;
    if ((startsWithNo || t.contains('mouse')) && hasStats) return true;

    // extremely long lines are rarely names
    if (t.length > 30) return true;

    return false;
  }

  static bool _hasStopWordToken(String cleanedLower) {
    final tokens = cleanedLower
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    return tokens.any(_stopWords.contains);
  }

  // ---------- Candidate scoring ----------
  static int _scoreNameCandidate({
    required String cleaned,
    required int index,
    required double lineHeight,
    required double yNorm, // 0 top -> 1 bottom
  }) {
    final lower = cleaned.toLowerCase();
    final squashed = _squashSpacesLower(cleaned);

    if (cleaned.length < 3) return -999;
    if (_looksLikeNonNameLine(lower) || _looksLikeNonNameLine(squashed)) {
      return -999;
    }
    if (_hasStopWordToken(lower)) return -999;
    if (lower.contains('tage')) return -999; // stageb/tagb garbage

    var score = 0;

    // prefer reasonable lengths
    if (cleaned.length >= 3 && cleaned.length <= 20) score += 14;
    if (cleaned.length >= 21 && cleaned.length <= 26) score += 7;

    // title-case starts
    if (RegExp(r'^[A-Z]').hasMatch(cleaned)) score += 6;

    // penalize ALL CAPS
    if (cleaned == cleaned.toUpperCase()) score -= 4;

    // prefer higher on card (names near top)
    score += ((1.0 - yNorm) * 18.0).round();

    // prefer larger font
    score += (lineHeight * 0.9).clamp(0, 18).round();

    // earlier lines slightly favored
    score += (10 - index).clamp(0, 10);

    return score;
  }

  // ---------- Number normalization (ONLY for numeric hunting) ----------
  static String _normalizeDigitsForNumbers(String s) {
    return s
        .replaceAll('O', '0')
        .replaceAll('o', '0')
        .replaceAll('I', '1')
        .replaceAll('l', '1')
        .replaceAll('|', '1')
        .replaceAll('S', '5')
        .replaceAll('s', '5');
  }

  static String _stripLeadingZeros(String s) {
    final n = int.tryParse(s.trim());
    return n == null ? s.trim() : n.toString();
  }

  // ---------- SVP promo extraction ----------
  static String? extractSvpNumberStringFromRaw(String rawText) {
    final t = _normalizeDigitsForNumbers(rawText);

    final m = RegExp(
      r'\bS\s*V\s*P\s*0*(\d{1,3})\b',
      caseSensitive: false,
    ).firstMatch(t);
    if (m == null) return null;

    final s = m.group(1);
    if (s == null) return null;
    return int.tryParse(s)?.toString();
  }

  static int? extractSvpNumberFromRaw(String raw) {
    final t = raw.toUpperCase();

    final patterns = <RegExp>[
      RegExp(r'\bS\s*V\s*P\s*0*([0-9]{1,3})\b'),
      RegExp(r'\bSVP\s*0*([0-9]{1,3})\b'),
      RegExp(r'\bSYP\s*0*([0-9]{1,3})\b'),
      RegExp(r'\bSYPO\s*0*([0-9]{1,3})\b'),
      RegExp(r'\bSVPO\s*0*([0-9]{1,3})\b'),
      RegExp(r'\b(?:SVP|SYP|SYPO|SVPO)\s*0*([0-9]{1,3})\b'),
    ];

    for (final re in patterns) {
      final m = re.firstMatch(t);
      if (m != null) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n >= 1 && n <= 102) return n;
      }
    }
    return null;
  }

  // ---------- Collector number extraction (NO guessing) ----------
  static ({String? number, String? setTotal}) _pickBestCollectorFraction(
    List<_LineBox> lineBoxes,
    String raw,
  ) {
    // We only accept fraction-like separators (/, |, I, l, -, en-dash/em-dash)
    // This avoids inventing pairs like "150 130" from random text.
    final frac = RegExp(
      r'([0-9]{1,4})\s*([/|Il\-\u2013\u2014])\s*([0-9]{2,4})',
    );

    final candidates = <_NumCandidate>[];

    bool looksLikeDamageLine(String sLower) {
      // filters out common body/attack text contexts
      return sLower.contains('damage') ||
          sLower.contains('does ') ||
          sLower.contains('do ') ||
          sLower.contains('thudding') ||
          sLower.contains('press') ||
          sLower.contains('ability') ||
          sLower.contains('evolves from');
    }

    void addMatches(String text, int lineIndex, double top, double left) {
      final t = _normalizeDigitsForNumbers(text);
      final lower = t.toLowerCase();

      // skip obvious non-number lines
      if (looksLikeDamageLine(lower)) return;

      for (final m in frac.allMatches(t)) {
        final num = m.group(1);
        final den = m.group(3);
        if (num == null || den == null) continue;

        final numInt = int.tryParse(num);
        final denInt = int.tryParse(den);
        if (numInt == null || denInt == null) continue;

        // plausibility: modern printed totals typically 60..400, keep it tight
        if (denInt < 40 || denInt > 400) continue;

        // numerator plausibility:
        // allow secret rares > printedTotal (e.g. 245/198), but not insane
        if (numInt < 1 || numInt > denInt + 300) continue;

        candidates.add(
          _NumCandidate(
            num: numInt,
            den: denInt,
            lineIndex: lineIndex,
            top: top,
            left: left,
          ),
        );
      }
    }

    // 1) scan all lines
    for (var i = 0; i < lineBoxes.length; i++) {
      addMatches(lineBoxes[i].text, i, lineBoxes[i].top, lineBoxes[i].left);
    }

    // 2) raw fallback
    if (candidates.isEmpty) {
      addMatches(raw, 999, 0, 0);
    }

    // 3) bottom-right bias pass (helps when OCR scatters the number)
    if (candidates.isEmpty && lineBoxes.isNotEmpty) {
      final bottomRight = [...lineBoxes]
        ..sort((a, b) {
          final c = b.top.compareTo(a.top);
          return c != 0 ? c : b.left.compareTo(a.left);
        });

      for (var i = 0; i < min(bottomRight.length, 60); i++) {
        addMatches(
          bottomRight[i].text,
          900 + i,
          bottomRight[i].top,
          bottomRight[i].left,
        );
        if (candidates.isNotEmpty) break;
      }
    }

    if (candidates.isEmpty) return (number: null, setTotal: null);

    int score(_NumCandidate c) {
      var s = 0;

      // prefer printed totals in modern range
      if (c.den >= 100 && c.den <= 400) {
        s += 90;
      } else if (c.den >= 60 && c.den < 100) {
        s += 40;
      } else {
        s -= 80;
      }

      // prefer realistic numerators
      if (c.num >= 1 && c.num <= c.den) {
        s += 25;
      } else if (c.num > c.den && c.num <= c.den + 250) {
        s += 20; // secret rare pattern
      } else {
        s -= 80;
      }

      // prefer lower and right on card
      s += (c.top / 18).clamp(0, 140).toInt();
      s += (c.left / 25).clamp(0, 60).toInt();

      // slight bias to later lines
      s += min(c.lineIndex, 80);

      return s;
    }

    candidates.sort((a, b) => score(b).compareTo(score(a)));
    final best = candidates.first;

    return (
      number: _stripLeadingZeros(best.num.toString()),
      setTotal: _stripLeadingZeros(best.den.toString()),
    );
  }

  // ---------- HP / Stage ----------
  static int? _extractHp(String raw) {
    final t = _normalizeDigitsForNumbers(raw);
    final lower = t.toLowerCase();

    // Trainers / Energy do not have HP
    if (lower.contains('trainer') ||
        lower.contains('supporter') ||
        lower.contains('item') ||
        lower.contains('stadium') ||
        lower.contains('energy')) {
      return null;
    }

    // Strong matches first (label present)
    final m1 = RegExp(
      r'\bHP\s*(\d{2,3})\b',
      caseSensitive: false,
    ).firstMatch(t);
    if (m1 != null) {
      final hp = int.tryParse(m1.group(1)!);
      if (hp != null && hp >= 10 && hp <= 400) return hp;
    }

    final m2 = RegExp(
      r'\b(\d{2,3})\s*HP\b',
      caseSensitive: false,
    ).firstMatch(t);
    if (m2 != null) {
      final hp = int.tryParse(m2.group(1)!);
      if (hp != null && hp >= 10 && hp <= 400) return hp;
    }

    final m3 = RegExp(
      r'\bH\s*P\s*(\d{2,3})\b',
      caseSensitive: false,
    ).firstMatch(t);
    if (m3 != null) {
      final hp = int.tryParse(m3.group(1)!);
      if (hp != null && hp >= 10 && hp <= 400) return hp;
    }

    // If OCR dropped the HP label entirely, do a *very* constrained fallback
    // only if it looks like a Pokémon card.
    final looksLikePokemonCard =
        lower.contains('evolves from') || lower.contains('ability');

    if (!looksLikePokemonCard) return null;

    final nums = RegExp(r'\b(\d{2,3})\b').allMatches(t).toList();
    int best = -1;

    for (final m in nums) {
      final s = m.group(1);
      final n = s == null ? null : int.tryParse(s);
      if (n == null) continue;
      if (n < 70 || n > 400) continue; // avoid common damage values
      if (n > best) best = n;
    }

    return best > 0 ? best : null;
  }

  static String? _extractStage(String raw) {
    final u = _deaccent(raw).toUpperCase();

    if (RegExp(r'\bBASIC\b').hasMatch(u) ||
        RegExp(r'\bB\s*A\s*S\s*I\s*C\b').hasMatch(u)) {
      return 'Basic';
    }
    if (RegExp(r'\bSTAGE\s*1\b').hasMatch(u) ||
        RegExp(r'\bSTAGE1\b').hasMatch(u) ||
        RegExp(r'STAGE\s*1').hasMatch(u)) {
      return 'Stage 1';
    }
    if (RegExp(r'\bSTAGE\s*[2Z]\b').hasMatch(u) ||
        RegExp(r'\bSTAGE[2Z]\b').hasMatch(u) ||
        RegExp(r'STAGE\s*[2Z]').hasMatch(u)) {
      return 'Stage 2';
    }
    return null;
  }

  // ---------- Name normalization ----------
  static String _normalizeSuffixes(String s) {
    var t = _deaccent(s).trim();

    // add spaces for glued suffixes: "Gardevoirex" -> "Gardevoir ex"
    t = t.replaceAllMapped(
      RegExp(r'([A-Za-z])((ex|EX|gx|GX|v|V|max|MAX|vstar|VSTAR))\b'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  static String _normalizePickedName(String s) {
    var t = _deaccent(s).trim();

    // strip BASIC-like headers even when glued
    // Examples: "SrAGIPGardevoir", "BẠSIGSnorlax"
    t = t.replaceAll(
      RegExp(
        r"^(?:[^A-Za-z]*)"
        r"(?:BASIC|BSIC|ASIC|SIC|BASIG|BAS1G|BA5IG|BẠSIG|SRAGIP)"
        r"\s*",
        caseSensitive: false,
      ),
      '',
    );

    // remove stage headers
    t = t.replaceAll(
      RegExp(r'^(?:STAGE\s*[12Z]|STAGE[12Z]|STAGEB)\s+', caseSensitive: false),
      '',
    );

    // fix common OCR: "Gardevoirek" / "Gardevoirex" -> "Gardevoir ex"
    t = t.replaceAllMapped(
      RegExp(r"^([A-Za-z][A-Za-z'\- ]{2,30})\s*e[kx]\b", caseSensitive: false),
      (m) => '${m.group(1)!.trim()} ex',
    );

    // remove Lv
    t = t.replaceAll(RegExp(r'\bLV\b', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\bLv\b', caseSensitive: false), '');

    // drop trailing single-letter junk
    t = t.replaceAll(RegExp(r'\s+[A-Za-z]\b'), '');

    // normalize suffix spacing
    t = _normalizeSuffixes(t);

    // Fix common OCR: "MewtwoX" => "Mewtwo GX"
    t = t.replaceAllMapped(
      RegExp(r"^([A-Za-z][A-Za-z'\- ]{2,30})(X)\b"),
      (m) => '${m.group(1)!.trim()} GX',
    );

    final lower = t.toLowerCase();
    if (_looksLikeNonNameLine(lower)) return '';
    if (_hasStopWordToken(lower)) return '';

    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length < 3) return '';

    // if still glued mess, try to salvage last TitleCase-ish token
    if (!t.contains(' ') && t.length > 10) {
      final m2 = RegExp(r'([A-Z][a-z]{2,})$').firstMatch(t);
      if (m2 != null) {
        final tail = m2.group(1)!;
        if (tail.length >= 4 && tail.length < t.length) t = tail;
      }
    }

    return t.trim();
  }

  // ---------- Name extraction ----------
  static String? _extractNameNearHp(String raw) {
    final t = _deaccent(raw).replaceAll('\n', ' ');

    final m = RegExp(
      r"(?:\bBASIC\b|\bBSIC\b|\bASIC\b|\bSIC\b|\bSTAGE\s*[12Z]\b|\bSTAGE[12Z]\b|\bSTAGEB\b)?\s*"
      r"([A-Za-z][A-Za-z'\-\s]{2,30}?)\s+"
      r"(?:HP\s*\d{2,3}|\d{2,3}\s*HP)\b",
      caseSensitive: false,
    ).firstMatch(t);

    if (m == null) return null;

    var name = m.group(1)?.trim();
    if (name == null || name.isEmpty) return null;

    name = _normalizePickedName(name);
    if (name.isEmpty) return null;

    return name;
  }

  static String? _extractNameFromRawLine(String rawLine) {
    final line = _deaccent(
      rawLine,
    ).replaceAll('\u00A0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) return null;

    final lowerLine = line.toLowerCase();

    // reject stat line
    final hasStats =
        lowerLine.contains('ht') ||
        lowerLine.contains('wt') ||
        lowerLine.contains('lbs');
    final hasPokemonWord =
        lowerLine.contains('pokemon') || lowerLine.contains('pokmon');
    final startsWithNo =
        lowerLine.startsWith('no ') ||
        lowerLine.startsWith('no.') ||
        lowerLine == 'no';
    if (hasStats && (hasPokemonWord || startsWithNo)) return null;

    String candidateRegion = line;

    // if "HP" appears, keep left side
    final hpMatch = RegExp(
      r'\bH\s*P\b',
      caseSensitive: false,
    ).firstMatch(candidateRegion);
    if (hpMatch != null && hpMatch.start > 0) {
      candidateRegion = candidateRegion.substring(0, hpMatch.start).trim();
    }

    // if "Pokemon" appears, keep left side
    final pokeMatch = RegExp(
      r'\bPOK(?:E)?MON\b',
      caseSensitive: false,
    ).firstMatch(candidateRegion);
    if (pokeMatch != null && pokeMatch.start > 0) {
      candidateRegion = candidateRegion.substring(0, pokeMatch.start).trim();
    }

    final cleaned = _cleanLineLetters(candidateRegion);
    if (cleaned.length < 3) return null;

    final picked = _normalizePickedName(cleaned);
    if (picked.isEmpty) return null;

    final pickedLower = picked.toLowerCase();
    if (_looksLikeNonNameLine(pickedLower)) return null;
    if (_hasStopWordToken(pickedLower)) return null;
    if (pickedLower.contains('tage')) return null;

    return picked;
  }

  static String? _extractNameFromTopArea(List<_LineBox> lineBoxes) {
    if (lineBoxes.isEmpty) return null;

    final minTop = lineBoxes.first.top;
    final maxTop = lineBoxes.last.top;
    final span = (maxTop - minTop).abs();
    final topCutoff = minTop + (span * 0.70);

    final candidates = <({String name, int score})>[];

    void considerLine(_LineBox lb, int i) {
      final picked = _extractNameFromRawLine(lb.text);
      if (picked == null || picked.isEmpty) return;

      final lower = picked.toLowerCase();
      if (_looksLikeNonNameLine(lower)) return;
      if (lower.contains('tage')) return;

      // avoid short attack-ish lines with digits
      if (RegExp(r'\b\d{1,3}\b').hasMatch(lb.text) &&
          picked.split(' ').length <= 3) {
        return;
      }

      double yNorm;
      if (span <= 0) {
        yNorm = 0.0;
      } else {
        final y = (lb.top - minTop) / span;
        yNorm = y < 0 ? 0.0 : (y > 1 ? 1.0 : y);
      }

      final sc = _scoreNameCandidate(
        cleaned: picked,
        index: i,
        lineHeight: lb.height,
        yNorm: yNorm,
      );

      if (sc > -200) {
        candidates.add((name: picked, score: sc));
      }
    }

    // pass 1: top area
    for (var i = 0; i < min(90, lineBoxes.length); i++) {
      final lb = lineBoxes[i];
      if (span > 0 && lb.top > topCutoff) continue;
      considerLine(lb, i);
    }

    // pass 2: fallback
    if (candidates.isEmpty) {
      for (var i = 0; i < min(140, lineBoxes.length); i++) {
        considerLine(lineBoxes[i], i);
      }
    }

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.first.name;
  }

  // ---------- Optional fields ----------
  static String? _extractIllustrator(String raw) {
    final t = _deaccent(raw).replaceAll('\n', ' ');
    final m = RegExp(
      r"\b(ILLUS\.?|ILLUSTRATOR)\s*[:\-]?\s*([A-Za-z .'-]{3,})",
      caseSensitive: false,
    ).firstMatch(t);
    if (m == null) return null;
    return m.group(2)?.trim();
  }

  static String? _extractRegulationMark(String raw) {
    final u = _deaccent(raw).toUpperCase();
    final m = RegExp(r'\b([D-H])\b').allMatches(u).toList();
    if (m.isEmpty) return null;
    return m.first.group(1);
  }

  static int? _extractCopyrightYear(String raw) {
    final m = RegExp(r'\b(19|20)\d{2}\b').allMatches(raw).toList();
    if (m.isEmpty) return null;
    final y = m.last.group(0);
    return y == null ? null : int.tryParse(y);
  }

  // ---------- Main ----------
  static Future<OcrGuess> recognizeFromImagePath(String path) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final input = InputImage.fromFilePath(path);
      final recognized = await recognizer.processImage(input);
      final raw = recognized.text.trim();

      final lineBoxes = <_LineBox>[];
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final txt = line.text.trim();
          if (txt.isEmpty) continue;
          final bb = line.boundingBox;
          lineBoxes.add(
            _LineBox(
              text: txt,
              top: bb.top.toDouble(),
              left: bb.left.toDouble(),
              height: bb.height.toDouble(),
            ),
          );
        }
      }

      // stable ordering: top->bottom then left->right
      lineBoxes.sort((a, b) {
        final c = a.top.compareTo(b.top);
        return c != 0 ? c : a.left.compareTo(b.left);
      });

      final frac = _pickBestCollectorFraction(lineBoxes, raw);
      final hp = _extractHp(raw);
      final stage = _extractStage(raw);
      print('🧾 FRACTION DEBUG → ${frac.number}/${frac.setTotal}');

      String? best = _extractNameNearHp(raw);
      best ??= _extractNameFromTopArea(lineBoxes);

      // final cleanup (handles your glued "SrAGIPGardevoirek" case)
      if (best != null && best.isNotEmpty) {
        final cleaned = _normalizePickedName(best);
        if (cleaned.isNotEmpty) best = cleaned;
      }

      if (debug) {
        // ignore: avoid_print
        print('--- OCR RAW ---\n$raw');
        // ignore: avoid_print
        print('--- OCR LINES (first 30) ---');
        for (var i = 0; i < min(lineBoxes.length, 30); i++) {
          final lb = lineBoxes[i];
          // ignore: avoid_print
          print(
            '[${i.toString().padLeft(2)}] top=${lb.top.toStringAsFixed(1)} '
            'left=${lb.left.toStringAsFixed(1)} h=${lb.height.toStringAsFixed(1)} :: ${lb.text}',
          );
        }
      }

      // keep your existing debug prints
      // ignore: avoid_print
      print('🧩 HP DEBUG raw.len=${raw.length}');
      // ignore: avoid_print
      print(
        '🧩 HP DEBUG raw.head="${raw.substring(0, raw.length > 180 ? 180 : raw.length)}"',
      );
      // ignore: avoid_print
      print('🧩 HP DEBUG extractedHp=$hp');
      // ignore: avoid_print
      print(
        '🔍 OCR DEBUG → name=$best, number=${frac.number}, setTotal=${frac.setTotal}, hp=$hp, stage=$stage',
      );

      return OcrGuess(
        name: best,
        number: frac.number,
        setTotal: frac.setTotal,
        hp: hp,
        stage: stage,
        rawText: raw,
        illustrator: _extractIllustrator(raw),
        regulationMark: _extractRegulationMark(raw),
        copyrightYear: _extractCopyrightYear(raw),
      );
    } finally {
      await recognizer.close();
    }
  }

  static String? extractTrainerTitleFromRaw(String rawText) {
    if (rawText.trim().isEmpty) return null;

    final lines = rawText
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    int idx = -1;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].toLowerCase();
      if (l == 'trainer' ||
          l == 'traner' ||
          l.startsWith('trainer') ||
          l.startsWith('traner')) {
        idx = i;
        break;
      }
    }
    if (idx < 0) return null;

    for (var j = idx + 1; j < lines.length && j <= idx + 6; j++) {
      final l = lines[j];
      final lower = l.toLowerCase();

      if (lower == 'supporter' || lower == 'item' || lower == 'stadium')
        continue;

      if (lower.contains('draw ') ||
          lower.contains('you may') ||
          lower.contains('cards')) {
        continue;
      }

      final hasLetters = RegExp(r'[A-Za-z]').hasMatch(l);
      if (!hasLetters) continue;

      final cleaned = l
          .replaceAll(RegExp(r"[^A-Za-z0-9\s'\-]"), ' ')
          .replaceAll(RegExp(r"\s+"), ' ')
          .trim();

      if (cleaned.length < 3 || cleaned.length > 30) continue;

      return cleaned;
    }
    return null;
  }

  /// Detect certain promos when OCR misses the collector number.
  /// Returns SVP slot digits if we are highly confident, else null.
  static int? detectSvpSlotBySignature(String raw) {
    // Normalize hard: uppercase + remove whitespace/punctuation so
    // "AbilityVoraciousness" still matches.
    final up = raw.toUpperCase();
    final flat = up.replaceAll(
      RegExp(r'[^A-Z0-9]'),
      '',
    ); // keep letters+digits only

    bool has(String needle) => flat.contains(needle);

    // Snorlax SVP 051 signature:
    // "Voraciousness" + "Thudding Press" + "Leftovers" (often OCR'd as Leftoyers/Leftov...)
    final hasVoracious = has('VORACIOUS');
    final hasThudding = has('THUDDING');
    final hasLefto = has(
      'LEFTO',
    ); // catches LEFTOVERS / LEFTOYERS / LEFT0VERS etc.

    if (hasVoracious && hasThudding && hasLefto) {
      return 51;
    }

    return null;
  }
}

class _LineBox {
  final String text;
  final double top;
  final double left;
  final double height;

  _LineBox({
    required this.text,
    required this.top,
    required this.left,
    required this.height,
  });
}

class _NumCandidate {
  final int num;
  final int den;
  final int lineIndex;
  final double top;
  final double left;

  _NumCandidate({
    required this.num,
    required this.den,
    required this.lineIndex,
    required this.top,
    required this.left,
  });
}
