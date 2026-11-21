import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/pressable.dart';
import '../common/ui_trace.dart';

import 'motion.dart';
import 'shapes.dart';
import 'surfaces.dart';

/// 玻璃表面:**模糊背后的内容 → 叠半透明填充 → 发丝描边 + 顶边高光 → 外投影**。
///
/// ```dart
/// GlassSurface(
///   tier: GlassTier.chrome,
///   stadium: true,
///   onTap: openSessions,
///   padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
///   child: Text('修复登录重复提交'),
/// )
/// ```
///
/// ## 性能约定
///
/// - 只有 [GlassTier.chrome] / [GlassTier.sheet] 默认真模糊;同屏真模糊的
///   元素控制在 3 个以内(顶栏、输入条、弹层)。
/// - 同屏多个**互不重叠**的模糊件(顶栏左圆钮 + 标题胶囊 + 右圆钮)放进同一个
///   `BackdropGroup`,并传 [grouped] = true,引擎只采一次背景。
/// - 模糊用 `ImageFilterConfig.blur(bounded: true)`:采样不越出形状边界,
///   边缘不会被外面的颜色"渗"进来(iOS 同款)。
/// - 降级:主题里 `DshSurfaces.blurEnabled == false`(设置"减少透明效果"/
///   低端机)或系统高对比度时,不创建 `BackdropFilter`,改用近乎不透明的
///   `fallbackFill` —— 观感是"磨砂纸",可读性不降。
/// - 路由切换(push/pop、上面压了新页)时也按 settled=0:过渡动画每一帧背景
///   都在动,采样等于白烧 GPU;切完 120ms 内淡回玻璃,静止时观感不变。
///
/// ## 为什么阴影要单独画
///
/// 玻璃内部是半透明的,普通 `BoxShadow` 画在形状下方会透过玻璃、又被模糊
/// 一次,玻璃中间发灰。这里用 even-odd 裁剪,只在形状**外部**画投影。
class GlassSurface extends StatefulWidget {
  const GlassSurface({
    super.key,
    this.tier = GlassTier.card,
    this.borderRadius,
    this.circle = false,
    this.stadium = false,
    this.padding,
    this.blur,
    this.grouped = false,
    this.settled,
    this.style,
    this.onTap,
    this.onLongPress,
    this.child,
  }) : assert(!(circle && stadium), 'circle 与 stadium 只能二选一' /* l10n:keep developer-only assertion */);

  /// 材质层级,决定默认的填充 / 模糊 / 阴影 / 圆角。
  final GlassTier tier;

  /// 连续圆角半径。缺省按层级:chrome / sheet 用 xl(28)、card 用 md(14)、
  /// pill 用胶囊。
  final BorderRadiusGeometry? borderRadius;

  /// 圆形(顶栏圆钮、发送键底座)。
  final bool circle;

  /// 胶囊(半径永远等于高度一半)。
  final bool stadium;

  final EdgeInsetsGeometry? padding;

  /// 强制开 / 关模糊。null = 跟随层级默认值与主题总开关。
  final bool? blur;

  /// 与同一 `BackdropGroup` 下的其他玻璃共享一次背景采样。
  final bool grouped;

  /// 会动的玻璃(升起、被拖动的弹层)。0 = 在动:不采样背景,用不透明填充。
  /// 停稳后走向 1:模糊立刻开,藏在近乎不透明的填充后面,填充渐变回玻璃,所以
  /// 模糊出现时不跳。和 `blur: false` 不同,切换时模糊层留在树里,子树不重建。
  /// null = 一直是玻璃。
  final double? settled;

  /// 覆盖主题给的材质(极少用;例如审批卡要换警示色描边)。
  final GlassStyle? style;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? child;

  @override
  State<GlassSurface> createState() => _GlassSurfaceState();

  static ImageFilterConfig _filterFor(double sigma, double saturation) {
    final blur = ImageFilterConfig.blur(sigmaX: sigma, sigmaY: sigma, bounded: true);
    if (saturation == 1) return blur;
    return ImageFilterConfig.compose(outer: ImageFilterConfig(ColorFilter.matrix(_saturate(saturation))), inner: blur);
  }

  /// 保亮度的饱和度矩阵(Rec. 709 权重)。
  static List<double> _saturate(double s) {
    final r = 0.2126 * (1 - s);
    final g = 0.7152 * (1 - s);
    final b = 0.0722 * (1 - s);
    return <double>[
      r + s, g, b, 0, 0, //
      r, g + s, b, 0, 0, //
      r, g, b + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }
}

/// 路由切换时 chrome 玻璃的 settled:切屏(push/pop、上面压了新页)时背景每帧
/// 都在动,BackdropFilter 每帧重采样等于白烧 GPU。过渡中按 settled=0 处理
/// (不透明填充、不采样),切完再用 [AppMotion.glassIn] 淡回玻璃,和
/// [SlidingGlass] 同一套思路。只认"在动"(animation / secondaryAnimation 任一
/// isAnimating),不认"被盖住":盖住不动时背景是静止的,采样一次就能复用。静止
/// 时观感、3 个模糊上限、blurEnabled / 高对比度降级都不变;不在路由里
/// (Overlay、测试裸 widget)时永远是玻璃。
class _GlassSurfaceState extends State<GlassSurface> with SingleTickerProviderStateMixin {
  /// Only surfaces that actually blur follow route motion. Keep the controller
  /// once created so enabling blur again reuses the same ticker.
  AnimationController? _routeSettled;
  bool _tracksRoute = false;
  Animation<double>? _route;
  Animation<double>? _secondary;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateRouteBinding();
  }

  @override
  void didUpdateWidget(GlassSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blur != widget.blur || oldWidget.tier != widget.tier || oldWidget.style != widget.style) {
      _updateRouteBinding();
    }
  }

  bool _reduceBlur(DshSurfaces surfaces) =>
      !surfaces.blurEnabled || (MediaQuery.maybeHighContrastOf(context) ?? false) || uiTraceNoBlur;

  void _updateRouteBinding() {
    final surfaces = DshSurfaces.of(context);
    final style = widget.style ?? surfaces.glass(widget.tier);
    _tracksRoute = !_reduceBlur(surfaces) && (widget.blur ?? style.blurs);
    if (!_tracksRoute) {
      _route?.removeStatusListener(_syncRoute);
      _secondary?.removeStatusListener(_syncRoute);
      _route = null;
      _secondary = null;
      _routeSettled?.stop();
      _routeSettled?.value = 1;
      return;
    }
    _routeSettled ??= AnimationController(vsync: this, duration: AppMotion.glassIn, value: 1);
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    final secondary = route?.secondaryAnimation;
    if (!identical(animation, _route) || !identical(secondary, _secondary)) {
      _route?.removeStatusListener(_syncRoute);
      _secondary?.removeStatusListener(_syncRoute);
      _route = animation;
      _secondary = secondary;
      _route?.addStatusListener(_syncRoute);
      _secondary?.addStatusListener(_syncRoute);
    }
    // 刚建出来时路由可能已经在动(push 进行中),按当前状态同步一次。
    _syncRoute();
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_syncRoute);
    _secondary?.removeStatusListener(_syncRoute);
    _routeSettled?.dispose();
    super.dispose();
  }

  /// 路由在动就按 settled=0;都停稳了再淡回玻璃。
  void _syncRoute([AnimationStatus? _]) {
    final settled = _routeSettled!;
    final moving = (_route?.status.isAnimating ?? false) || (_secondary?.status.isAnimating ?? false);
    if (moving) {
      if (settled.value != 0) settled.value = 0;
    } else if (settled.value != 1) {
      if (AppMotion.reduced(context)) {
        settled.value = 1;
      } else if (!settled.isForwardOrCompleted) {
        settled.forward();
      }
    }
  }

  /// 外面传的 settled(SlidingGlass)与路由 settled 取最小:任一说"在动"就 opaque。
  double _effectiveSettled() {
    final settled = widget.settled;
    final route = _routeSettled!.value;
    if (settled == null) return route;
    return settled < route ? settled : route;
  }

  BorderRadiusGeometry get _radius =>
      widget.borderRadius ??
      switch (widget.tier) {
        GlassTier.chrome || GlassTier.sheet => AppShape.radiusXl,
        GlassTier.card => AppShape.radiusMd,
        GlassTier.pill => AppShape.radiusLg,
      };

  bool get _isStadium =>
      widget.stadium || (!widget.circle && widget.borderRadius == null && widget.tier == GlassTier.pill);

  ShapeBorder get _shape {
    if (widget.circle) return const CircleBorder();
    if (_isStadium) return const StadiumBorder();
    return RoundedSuperellipseBorder(borderRadius: _radius);
  }

  @override
  Widget build(BuildContext context) {
    if (!_tracksRoute) return _buildGlass(context, 1, widget.child);
    return AnimatedBuilder(
      animation: _routeSettled!,
      builder: (context, child) => _buildGlass(context, _effectiveSettled(), child),
      child: widget.child,
    );
  }

  Widget _buildGlass(BuildContext context, double settled, Widget? child) {
    final surfaces = DshSurfaces.of(context);
    final s = widget.style ?? surfaces.glass(widget.tier);
    final reduce = _reduceBlur(surfaces);
    final useBlur = !reduce && (widget.blur ?? s.blurs);
    if (uiTraceEnabled) {
      uiTrace('glass', 'build', {'tier': widget.tier.name, 'blur': useBlur, 'grouped': widget.grouped});
    }
    final fill = useBlur ? Color.lerp(s.fallbackFill, s.fill, settled)! : (reduce || s.blurs ? s.fallbackFill : s.fill);
    final shape = _shape;
    final textDirection = Directionality.maybeOf(context);

    Widget content = child ?? const SizedBox.shrink();
    if (widget.padding != null) content = Padding(padding: widget.padding!, child: content);
    if (widget.onTap != null || widget.onLongPress != null) {
      // Press feedback on the content, not the glass: scaling a surface that
      // blurs would re-sample what is behind it at a new size every frame.
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: shape,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: Pressable(behavior: HitTestBehavior.translucent, child: content),
        ),
      );
    }

    content = CustomPaint(
      foregroundPainter: _GlassEdgePainter(
        shape: shape,
        hairline: s.hairline,
        hairlineWidth: s.hairlineWidth,
        rim: s.rim,
        textDirection: textDirection,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, color: fill),
        child: content,
      ),
    );

    if (useBlur) {
      final config = GlassSurface._filterFor(s.blurs ? s.blurSigma : 14, s.saturation);
      final sampling = settled != 0;
      content = widget.grouped
          ? BackdropFilter.grouped(filterConfig: config, enabled: sampling, child: content)
          : BackdropFilter(filterConfig: config, enabled: sampling, child: content);
      content = _clip(content);
    }

    if (s.shadows.isNotEmpty) {
      content = CustomPaint(
        painter: _GlassShadowPainter(shape: shape, shadows: s.shadows, textDirection: textDirection),
        child: content,
      );
    }
    return content;
  }

  Widget _clip(Widget child) {
    if (widget.circle) return ClipOval(child: child);
    if (_isStadium) {
      return ClipRRect(borderRadius: const BorderRadius.all(Radius.circular(999)), child: child);
    }
    return ClipRSuperellipse(borderRadius: _radius, child: child);
  }
}

/// 发丝描边 + 顶边高光。描边画在形状内侧,裁剪时不会被切掉一半。
class _GlassEdgePainter extends CustomPainter {
  _GlassEdgePainter({
    required this.shape,
    required this.hairline,
    required this.hairlineWidth,
    required this.rim,
    required this.textDirection,
  });

  final ShapeBorder shape;
  final Color hairline;
  final double hairlineWidth;
  final Color rim;
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final width = math.max(hairlineWidth, 0.5);
    final path = shape.getOuterPath(rect.deflate(width / 2), textDirection: textDirection);
    if (hairline.a > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = hairline,
      );
    }
    if (rim.a > 0) {
      final highlight = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(width, 0.8)
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [rim, rim.withValues(alpha: 0)],
          stops: const [0, 0.45],
        ).createShader(rect);
      canvas.drawPath(path, highlight);
    }
  }

  @override
  bool shouldRepaint(_GlassEdgePainter old) =>
      old.shape != shape ||
      old.hairline != hairline ||
      old.hairlineWidth != hairlineWidth ||
      old.rim != rim ||
      old.textDirection != textDirection;
}

/// 只在形状外部画的投影。
class _GlassShadowPainter extends CustomPainter {
  _GlassShadowPainter({required this.shape, required this.shadows, required this.textDirection});

  final ShapeBorder shape;
  final List<BoxShadow> shadows;
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    var extent = 0.0;
    for (final s in shadows) {
      extent = math.max(extent, s.blurRadius * 2 + s.spreadRadius.abs() + s.offset.distance);
    }
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(extent + 2))
      ..addPath(shape.getOuterPath(rect, textDirection: textDirection), Offset.zero);
    canvas.save();
    canvas.clipPath(outside);
    for (final s in shadows) {
      canvas.drawPath(
        shape.getOuterPath(rect.shift(s.offset).inflate(s.spreadRadius), textDirection: textDirection),
        s.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassShadowPainter old) =>
      old.shape != shape || !_sameShadows(old.shadows, shadows) || old.textDirection != textDirection;

  static bool _sameShadows(List<BoxShadow> a, List<BoxShadow> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The glass of a panel that slides in and out on [motion] (0..1): an opaque fill while it
/// moves, since a moving blur re-samples what is behind it every frame, and glass at rest.
/// Once it stops, the opaque fill clears into glass over [AppMotion.glassIn]. Moving uses
/// the opaque fill immediately so disabling the blur cannot expose sharp background text.
/// The blur stays in the tree throughout, so the panel's content is not rebuilt either.
class SlidingGlass extends StatefulWidget {
  const SlidingGlass({super.key, required this.motion, required this.tier, required this.borderRadius, this.child});

  final Animation<double> motion;
  final GlassTier tier;
  final BorderRadiusGeometry borderRadius;
  final Widget? child;

  @override
  State<SlidingGlass> createState() => _SlidingGlassState();
}

class _SlidingGlassState extends State<SlidingGlass> with SingleTickerProviderStateMixin {
  late final AnimationController _settled = AnimationController(
    vsync: this,
    duration: AppMotion.glassIn,
    value: widget.motion.value == 1 ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    widget.motion.addListener(_sync);
  }

  @override
  void didUpdateWidget(SlidingGlass old) {
    super.didUpdateWidget(old);
    if (identical(old.motion, widget.motion)) return;
    old.motion.removeListener(_sync);
    widget.motion.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    widget.motion.removeListener(_sync);
    _settled.dispose();
    super.dispose();
  }

  void _sync() {
    final value = widget.motion.value;
    if (value == 0) {
      // Out of sight: nothing to fade, and no reason to keep sampling.
      if (_settled.value != 0) _settled.value = 0;
    } else if (AppMotion.reduced(context)) {
      _settled.value = value == 1 ? 1 : 0;
    } else if (value == 1) {
      if (!_settled.isForwardOrCompleted) _settled.forward();
    } else if (_settled.isForwardOrCompleted) {
      _settled.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _settled,
    builder: (context, child) =>
        GlassSurface(tier: widget.tier, borderRadius: widget.borderRadius, settled: _settled.value, child: child),
    child: widget.child,
  );
}

/// [child]'s glass without its blur, for chrome floating over a web page: the page is a
/// native view, which a backdrop filter can't see. It would blur whatever Flutter drew
/// underneath instead, and show it through the key as a band.
class GlassOverNativeView extends StatelessWidget {
  const GlassOverNativeView({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    if (!surfaces.blurEnabled) return child;
    return Theme(
      data: theme.copyWith(
        extensions: [
          for (final e in theme.extensions.values)
            if (e is! DshSurfaces) e,
          surfaces.copyWith(blurEnabled: false),
        ],
      ),
      child: child,
    );
  }
}
