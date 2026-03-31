import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pokemon_models.dart';

class PokemonCardShowcase extends StatefulWidget {
  final PokemonCardResult card;
  final bool animate;
  final bool grayscale;
  final Animation<double>? flip;
  final Widget? backContent;
  final String? fallbackLabel;
  final double borderRadius;
  final Color backgroundColor;
  final BoxFit fit;

  const PokemonCardShowcase({
    super.key,
    required this.card,
    this.animate = true,
    this.grayscale = false,
    this.flip,
    this.backContent,
    this.fallbackLabel,
    this.borderRadius = 18,
    this.backgroundColor = const Color(0xFF111A2E),
    this.fit = BoxFit.cover,
  });

  @override
  State<PokemonCardShowcase> createState() => _PokemonCardShowcaseState();
}

class _PokemonCardShowcaseState extends State<PokemonCardShowcase>
    with SingleTickerProviderStateMixin {
  AnimationController? _idle;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _idle = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 8),
      )..repeat();
    }
  }

  @override
  void didUpdateWidget(covariant PokemonCardShowcase oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!oldWidget.animate && widget.animate) {
      _idle = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 8),
      )..repeat();
    } else if (oldWidget.animate && !widget.animate) {
      _idle?.stop();
      _idle?.dispose();
      _idle = null;
    }
  }

  @override
  void dispose() {
    _idle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[];
    if (_idle != null) {
      listenables.add(_idle!);
    }
    if (widget.flip != null) {
      listenables.add(widget.flip!);
    }

    final child = listenables.isEmpty
        ? _buildTransformedCard()
        : AnimatedBuilder(
            animation: Listenable.merge(listenables),
            builder: (context, _) => _buildTransformedCard(),
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: 24,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: Container(color: widget.backgroundColor, child: child),
      ),
    );
  }

  Widget _buildTransformedCard() {
    final idleValue = _idle?.value ?? 0.0;
    final t = idleValue * 2 * math.pi;
    final floatY = widget.animate ? math.sin(t) * 5.0 : 0.0;
    final flipAngle = (widget.flip?.value ?? 0.0) * math.pi;
    final showingBack =
        widget.backContent != null &&
        widget.flip != null &&
        flipAngle > (math.pi / 2);

    final content = showingBack
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..rotateY(math.pi),
            child: widget.backContent!,
          )
        : _buildFront();

    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0013)
      ..translate(0.0, floatY)
      ..rotateY(flipAngle);

    return Transform(
      alignment: Alignment.center,
      transform: matrix,
      child: content,
    );
  }

  Widget _buildFront() {
    final img = widget.card.imageLarge.isNotEmpty
        ? widget.card.imageLarge
        : widget.card.imageSmall;
    final hasImg = img.startsWith('http://') || img.startsWith('https://');

    Widget front = hasImg
        ? Image.network(
            img,
            fit: widget.fit,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, __, ___) => _fallback(),
          )
        : _fallback();

    if (widget.grayscale) {
      front = ColorFiltered(
        colorFilter: const ColorFilter.matrix(_greyMatrix),
        child: front,
      );
    }

    return front;
  }

  Widget _fallback() {
    final label = widget.fallbackLabel?.trim().isNotEmpty == true
        ? widget.fallbackLabel!
        : (widget.card.name.isNotEmpty ? widget.card.name : 'Card');

    return Container(
      color: widget.backgroundColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
        ),
      ),
    );
  }
}

const List<double> _greyMatrix = <double>[
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
];
