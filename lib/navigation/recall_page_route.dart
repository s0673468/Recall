import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Builds the host platform's expected push/pop transition.
Route<T> buildRecallPageRoute<T>({
  required bool nativeIos,
  required WidgetBuilder builder,
}) => nativeIos
    ? CupertinoPageRoute<T>(builder: builder)
    : MaterialPageRoute<T>(builder: builder);
