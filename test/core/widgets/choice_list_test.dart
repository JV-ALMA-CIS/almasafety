import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/widgets/choice_list.dart';

const _items = [
  ChoiceItem(value: 'a', title: 'Alpha', subtitle: 'First'),
  ChoiceItem(value: 'b', title: 'Beta', subtitle: 'Second'),
];

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('a "none" row stands for "all" and is chosen when nothing is', (
    tester,
  ) async {
    String? selected = 'a';
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => ChoiceList<String>(
            items: _items,
            selected: selected,
            noneLabel: 'All projects',
            onChanged: (value) => setState(() => selected = value),
          ),
        ),
      ),
    );

    await tester.tap(find.text('All projects'));
    await tester.pump();
    expect(selected, isNull);

    // With a "none" row, tapping the chosen option keeps it (the "All"
    // row is how you clear a filter).
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('Beta'));
    await tester.pump();
    expect(selected, 'b');
  });

  testWidgets('allowDeselect false keeps a required choice chosen', (
    tester,
  ) async {
    String? selected = 'a';
    await tester.pumpWidget(
      _host(
        ChoiceList<String>(
          items: _items,
          selected: selected,
          allowDeselect: false,
          onChanged: (value) => selected = value,
        ),
      ),
    );

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(selected, 'a');
  });

  testWidgets('a validator takes part in the surrounding Form', (tester) async {
    final formKey = GlobalKey<FormState>();
    await tester.pumpWidget(
      _host(
        Form(
          key: formKey,
          child: ChoiceList<String>(
            items: _items,
            selected: null,
            onChanged: (_) {},
            validator: (value) => value == null ? 'Choose one.' : null,
          ),
        ),
      ),
    );

    expect(formKey.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('Choose one.'), findsOneWidget);
  });

  testWidgets('MultiChoiceList ticks and unticks any number of options', (
    tester,
  ) async {
    var selected = <String>{};
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => MultiChoiceList<String>(
            items: _items,
            selected: selected,
            onChanged: (next) => setState(() => selected = next),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Beta'));
    await tester.pump();
    expect(selected, {'a', 'b'});

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(selected, {'b'});
  });

  testWidgets('each option shows its detail line', (tester) async {
    await tester.pumpWidget(
      _host(
        ChoiceList<String>(items: _items, selected: null, onChanged: (_) {}),
      ),
    );
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
  });
}
