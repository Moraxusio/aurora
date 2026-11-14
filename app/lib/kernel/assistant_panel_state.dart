// Session membership is runtime-only. Dock geometry is a user preference.
class AssistantPanelState {
  final List<String> _ids = [];
  String? active;
  bool visible = false, maximized = false;
  double width;
  AssistantPanelState({this.width = 420});
  List<String> get ids => List.unmodifiable(_ids);
  void activate(String id) {
    if (!_ids.contains(id)) _ids.add(id);
    active = id;
    visible = true;
  }

  void remove(String id) {
    final index = _ids.indexOf(id);
    if (index < 0) return;
    _ids.removeAt(index);
    if (active == id) {
      active = _ids.isEmpty ? null : _ids[index.clamp(0, _ids.length - 1)];
    }
  }
}
