// The feature list, fixed at compile time like the agent's service list
// (D-40). Order here is the order of the activity bar.
import '../features/files/files_feature.dart';
import '../features/files/transfers.dart';
import '../features/git/git_feature.dart';
import '../features/monitor/monitor_view.dart';
import '../features/net/net_feature.dart';
import '../features/proxy/proxy_feature.dart';
import '../features/systemd/systemd_feature.dart';
import '../features/terminal/terminal_feature.dart';
import 'feature.dart';

class Features {
  final Transfers transfers;
  final ForwardManager forwards;
  late final List<Feature> all;

  Features({Transfers? transfers, ForwardManager? forwards})
      : transfers = transfers ?? Transfers(),
        forwards = forwards ?? ForwardManager() {
    all = [
      const TerminalFeature(),
      FilesFeature(this.transfers),
      const GitFeature(),
      const MonitorFeature(),
      const SystemdFeature(),
      NetFeature(this.forwards),
      const ProxyFeature(),
    ];
  }

  Feature? byId(String id) {
    for (final f in all) {
      if (f.id == id) return f;
    }
    return null;
  }

  void dispose() {
    forwards.dispose();
    transfers.dispose();
  }
}
