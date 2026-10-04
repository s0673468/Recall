import 'package:flutter/widgets.dart';

/// Rebuilds [builder] only when the value picked by [selector] changes,
/// instead of on every notification from [listenable].
///
/// The review controller notifies for many unrelated reasons (sync badge
/// ticks, flag notices, the rating lock). Surfaces that depend on one slice of
/// its state use this to skip the rest. A rebuild of the parent always
/// re-reads the selector, so captured state stays current.
class ListenableSelector<T> extends StatefulWidget {
  final Listenable listenable;
  final T Function() selector;
  final Widget Function(BuildContext context, T value) builder;

  /// Defaults to `==`. Pass [identical] for collections replaced wholesale.
  final bool Function(T previous, T next)? equals;

  const ListenableSelector({
    super.key,
    required this.listenable,
    required this.selector,
    required this.builder,
    this.equals,
  });

  @override
  State<ListenableSelector<T>> createState() => _ListenableSelectorState<T>();
}

class _ListenableSelectorState<T> extends State<ListenableSelector<T>> {
  late T _value;

  @override
  void initState() {
    super.initState();
    _value = widget.selector();
    widget.listenable.addListener(_onNotify);
  }

  @override
  void didUpdateWidget(covariant ListenableSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_onNotify);
      widget.listenable.addListener(_onNotify);
    }
    _value = widget.selector();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onNotify);
    super.dispose();
  }

  void _onNotify() {
    final next = widget.selector();
    final same = widget.equals?.call(_value, next) ?? _value == next;
    if (same) return;
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
