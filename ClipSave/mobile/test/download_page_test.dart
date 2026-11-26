import 'package:clipsave/main.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _UnavailableDocuments extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => null;
}

void main() {
  testWidgets('settings, empty history, and invalid link feedback', (
    tester,
  ) async {
    final platform = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _UnavailableDocuments();
    addTearDown(() => PathProviderPlatform.instance = platform);
    await tester.pumpWidget(const ClipSave());
    await tester.pumpAndSettle();

    expect(find.text('ClipSave'), findsOneWidget);
    expect(find.text('Saved videos'), findsOneWidget);
    expect(find.text('Download MP4'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Backend address'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'https://example.com');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'invalid-link');
    await tester.tap(find.text('Preview link'));
    await tester.pumpAndSettle();
    expect(
      find.text('Paste a direct MP4 or YouTube Shorts link.'),
      findsOneWidget,
    );
  });
}
