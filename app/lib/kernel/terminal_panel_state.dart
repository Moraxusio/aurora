// Terminal sessions have a separate host, selection and lifetime from editors.
// Visibility never closes a session. Only geometry, not session IDs, is saved.
class TerminalPanelState {
  static const defaultHeight = 260.0;
  final List<String> _ids = [];
  String? active;
  bool visible = false, maximized = false;
  double height;

  TerminalPanelState({this.height = defaultHeight});
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

  bool move(String id, int slot) {
    final from = _ids.indexOf(id);
    if (from < 0) return false;
    var to = slot.clamp(0, _ids.length);
    if (to > from) to--;
    if (from == to) return false;
    _ids.removeAt(from);
    _ids.insert(to, id);
    return true;
  }
}
