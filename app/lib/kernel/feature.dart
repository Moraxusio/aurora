// The client's kernel contract (docs/DESIGN.md D-78). The kernel owns the
// connection, the layout, the editor tabs and the command palette. A feature
// is a client for one agent service (D-45): it declares which service and
// which operations it needs, and the kernel shows it only when the agent
// reports them (D-30). Features never call each other; what they share goes
// through the Workspace (tabs, toasts, models), as agent services share the
// agent's kernel (D-40).
import 'dart:async';

import 'package:flutter/material.dart';

import 'workspace.dart';

/// One entry of the command palette.
class Command {
  final String id;
  final String title;
  final String group;
  final IconData? icon;

  /// Shown on the right, e.g. "Ctrl+B"; the binding itself is the shell's.
  final String? shortcut;
  final bool Function()? enabled;
  final FutureOr<void> Function() run;
  const Command({required this.id, required this.title, required this.group, required this.run, this.icon, this.shortcut, this.enabled});
}

/// What a feature puts in the side bar.
class SideBarView {
  final String title;
  final List<Widget> actions;
  final Widget body;
  const SideBarView({required this.title, required this.body, this.actions = const []});
}

/// Why a feature can or cannot be used on this server.
enum FeatureState {
  /// The agent's service list has not arrived yet (just connected). Nothing is
  /// known about the feature, so it is neither offered nor called missing.
  loading,

  /// The agent reports the service on, with all the operations.
  available,

  /// The service is switched off (D-9); the user can switch it on.
  disabled,

  /// The service is on but cannot work (a program it needs is missing, D-43).
  unavailable,

  /// The service is there but lacks an operation: the agent is older.
  outdated,

  /// The agent does not report the service at all.
  unreported,
}

abstract class Feature {
  const Feature();

  String get id;
  String get title;
  IconData get icon;

  /// The agent service this is the client of (agent.services `id`).
  String get service;

  /// Operations used; an agent that lacks one makes the feature [FeatureState.outdated].
  List<String> get ops;

  /// The side bar, or null when the feature has none and [open] shows its
  /// tab instead.
  SideBarView? sideBar(BuildContext context, Workspace ws);

  /// Called when the feature has no side bar and its activity icon is chosen.
  void open(Workspace ws) {}

  /// Commands for the palette. Called when the palette opens.
  List<Command> commands(Workspace ws) => const [];
}
