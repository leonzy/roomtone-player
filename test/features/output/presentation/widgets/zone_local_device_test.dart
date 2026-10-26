import 'package:flutter_test/flutter_test.dart';
import 'package:songloft_flutter/features/output/domain/output_models.dart';
import 'package:songloft_flutter/features/output/presentation/providers/output_provider.dart';
import 'package:songloft_flutter/features/output/presentation/widgets/zone_display.dart';

OutputDevice _player(String id) => OutputDevice(
  id: id,
  kind: OutputKind.local,
  name: id,
  online: true,
  volume: 50,
);

OutputGroup _group(String id, String name, String playerId) => OutputGroup(
  id: id,
  name: name,
  icon: '',
  masterId: playerId,
  members: <OutputMember>[OutputMember(playerId: playerId)],
  memberCaps: <MemberCaps>[
    MemberCaps(playerId: playerId, kind: OutputKind.local, online: true),
  ],
  status: const OutputStatus(),
);

void main() {
  // 别的客户端注册的也是 kind=local：区域「是否含本机」必须按设备 id 判断，
  // 否则会把别人的区域当成自己的，在本机播别人的歌并污染本机所在区域。
  test('isLocal 只认本机设备 id，不认 kind=local', () {
    final state = OutputState(
      players: <OutputDevice>[_player('me'), _player('phone')],
      groups: <OutputGroup>[
        _group('g-me', '本机', 'me'),
        _group('g-phone', '手机', 'phone'),
      ],
    );

    final zones = buildZoneEntries(state, localDeviceId: 'me');
    final me = zones.firstWhere((z) => z.id == 'g-me');
    final phone = zones.firstWhere((z) => z.id == 'g-phone');

    expect(me.isLocal, isTrue);
    expect(phone.isLocal, isFalse, reason: '别人的 local 设备不是本机');
  });

  test('设备 id 未知时退回旧判定，避免启动瞬间列表闪一下', () {
    final state = OutputState(
      players: <OutputDevice>[_player('me')],
      groups: <OutputGroup>[_group('g-me', '本机', 'me')],
    );

    final zones = buildZoneEntries(state);
    expect(zones.single.isLocal, isTrue);
  });
}
