import 'package:dms_client/src/state/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isNewerVersion', () {
    expect(isNewerVersion('v1.3.0', '1.2.0'), isTrue);
    expect(isNewerVersion('v1.10.0', '1.9.9'), isTrue);
    expect(isNewerVersion('v2.0', '1.9.9'), isTrue);
    expect(isNewerVersion('v1.2.0', '1.2.0'), isFalse);
    expect(isNewerVersion('v1.1.9', '1.2.0'), isFalse);
  });
}
