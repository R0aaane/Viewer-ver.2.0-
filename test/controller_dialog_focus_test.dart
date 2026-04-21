import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/models/mediaItem.dart';
import 'package:pdf_viewer/scene/rename_item_dialog.dart';

void main() {
  const item = MediaItem(
    id: '/library/sample.pdf',
    displayName: 'sample.pdf',
    kind: MediaKind.pdf,
    folderRaw: '/library',
  );

  testWidgets('rename dialog gives initial focus to the text field', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_RenameDialogHost(item: item));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);
    expect(find.text('キャンセル'), findsOneWidget);
    expect(find.text('変更'), findsOneWidget);
  });

  testWidgets('rename dialog returns null when cancelled', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_RenameDialogHost(item: item));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    expect(find.text('result:null'), findsOneWidget);
  });

  testWidgets('rename dialog returns trimmed value when submitted', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_RenameDialogHost(item: item));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  renamed  ');
    await tester.tap(find.text('変更'));
    await tester.pumpAndSettle();

    expect(find.text('result:renamed'), findsOneWidget);
  });
}

class _RenameDialogHost extends StatefulWidget {
  final MediaItem item;

  const _RenameDialogHost({required this.item});

  @override
  State<_RenameDialogHost> createState() => _RenameDialogHostState();
}

class _RenameDialogHostState extends State<_RenameDialogHost> {
  String _result = 'unset';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (innerContext) => Column(
            children: [
              TextButton(
                onPressed: () async {
                  final result = await showRenameItemDialog(
                    innerContext,
                    item: widget.item,
                  );
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _result = result ?? 'null';
                  });
                },
                child: const Text('open'),
              ),
              Text('result:$_result'),
            ],
          ),
        ),
      ),
    );
  }
}
