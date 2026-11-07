// What a systemd unit is doing, from the two fields `systemctl list-units`
// gives: ActiveState ("active", "failed", ...) and SubState ("running",
// "exited", "dead", ...). "active" alone is not "running": a one-shot unit
// that finished with RemainAfterExit stays active (exited) and has nothing to
// stop.
enum UnitKind {
  /// A process of the unit is running.
  running,

  /// Ran and finished; systemd keeps it active. Nothing to stop.
  exited,

  /// Ended with an error.
  failed,

  /// Starting, stopping or reloading right now.
  busy,

  /// Not running.
  stopped,
}

UnitKind unitKind(String active, String sub) => switch (active) {
      'failed' => UnitKind.failed,
      'activating' || 'deactivating' || 'reloading' => UnitKind.busy,
      'active' => sub == 'exited' ? UnitKind.exited : UnitKind.running,
      _ => UnitKind.stopped,
    };

/// The unit-file state in words a user reads (enabled, disabled, static, ...).
String fileStateText(String file) => switch (file) {
      'enabled' || 'enabled-runtime' => '开机自启',
      'disabled' => '不自启',
      'static' => '由其它单元启动',
      'masked' || 'masked-runtime' => '已屏蔽',
      'indirect' => '间接启用',
      'generated' || 'transient' => '自动生成',
      '' => '',
      _ => file,
    };

/// The short note after a unit's name.
String unitNote(UnitKind kind, String file) => switch (kind) {
      UnitKind.running => fileStateText(file),
      UnitKind.exited => '已执行完',
      UnitKind.failed => '失败',
      UnitKind.busy => '处理中…',
      UnitKind.stopped => '未运行',
    };
