import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Simple OCR output model (kept here so you don't need to edit other files)
class CardGuess {
  final String name;
  final String? number;
  const CardGuess({required this.name, required this.number});
}

class PokemonOcr {
  static Future<CardGuess> recognizeFromImagePath(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return const CardGuess(name: '', number: null);
    }

    final inputImage = InputImage.fromFilePath(path);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      final recognized = await recognizer.processImage(inputImage);

      final allText = recognized.text.replaceAll('\n', ' ');
      final number = _extractNumber(allText);

      final lines = <String>[];
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final t = line.text.trim();
          if (t.isNotEmpty) lines.add(t);
        }
      }

      final name = _extractBestName(lines, fallbackText: allText);

      return CardGuess(name: name, number: number);
    } catch (_) {
      return const CardGuess(name: '', number: null);
    } finally {
      recognizer.close();
    }
  }

  static String _extractBestName(
    List<String> lines, {
    required String fallbackText,
  }) {
    String clean(String raw) {
      var s = raw.replaceAll('’', "'");

      s = s.replaceAll(
        RegExp(
          r'\b(BASIC|BSIC|STAGE|TRAINER|ENERGY|POK[EÉ]MON)\b',
          caseSensitive: false,
        ),
        ' ',
      );

      // keep letters/numbers/spaces/hyphen/apostrophe
      s = s.replaceAll(RegExp(r"[^A-Za-z0-9\s\-']"), ' ');
      s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      return s;
    }

    bool isJunk(String s) {
      final t = s.toLowerCase();
      if (RegExp(r'[a-zA-Z]').allMatches(s).length < 3) return true;

      const junk = {
        'basic',
        'bsic',
        'stage',
        'trainer',
        'energy',
        'pokemon',
        'pokémon',
        'hp',
        'weakness',
        'resistance',
        'retreat',
      };
      if (junk.contains(t)) return true;
      return false;
    }

    int score(String s) {
      var sc = 0;
      sc += RegExp(r'[A-Za-z]').allMatches(s).length.clamp(0, 20);
      sc -= RegExp(r'\d').allMatches(s).length * 2;

      final words = s.split(' ').where((w) => w.isNotEmpty).toList();
      if (words.isNotEmpty && words.length <= 3) sc += 6;

      if (isJunk(s)) sc -= 10;
      return sc;
    }

    String best = '';
    var bestScore = -99999;

    for (final line in lines) {
      final c = clean(line);
      if (c.isEmpty) continue;
      final sc = score(c);
      if (sc > bestScore) {
        bestScore = sc;
        best = c;
      }
    }

    if (best.isEmpty) {
      // IMPORTANT: use double-quoted raw string here, because the pattern contains apostrophes
      final m = RegExp(
        r"\b([A-Za-z][A-Za-z'\-]{2,})(?:\s+([A-Za-z][A-Za-z'\-]{2,}))?\b",
      ).firstMatch(fallbackText);
      if (m != null) {
        best = clean('${m.group(1)} ${m.group(2) ?? ''}');
      }
    }

    return best.trim();
  }

  static String? _extractNumber(String allText) {
    final t = allText.replaceAll(' ', '');

    // 58/102
    final m1 = RegExp(r'(\d{1,3})/(\d{1,3})').firstMatch(t);
    if (m1 != null) return m1.group(1);

    // OCR sometimes reads "/" as I/l/|
    final m2 = RegExp(r'(\d{1,3})[Il|](\d{1,3})').firstMatch(t);
    if (m2 != null) return m2.group(1);

    // "No. 58"
    final m3 = RegExp(
      r'(?:no\.?|№)\s*(\d{1,3})',
      caseSensitive: false,
    ).firstMatch(allText);
    if (m3 != null) return m3.group(1);

    return null;
  }
}
