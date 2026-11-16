/// Aurora GUI public API. Feature code imports this library for controls,
/// composite widgets, layout primitives and the shared overlay system.
///
/// Familiar Flutter control names are adapters owned here: density, focus,
/// accessibility and theme changes propagate to every feature.
library;

export 'package:flutter/material.dart'
    hide TextField, FilledButton, OutlinedButton, TextButton, AlertDialog;

export '../theme/workbench_tokens.dart';
export 'controls.dart';
export 'workbench_components.dart';
export 'panels.dart';
