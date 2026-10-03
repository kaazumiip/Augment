import 'package:augment_app/social_page.dart';
import 'package:augment_app/social_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ended community poll shows question, colored result bars and footer',
      (tester) async {
    final post = SocialPost(
      id: 'poll-1',
      authorId: 'author-1',
      authorName: 'Jose',
      body: 'Which song should we arrange next?',
      createdAt: DateTime(2026),
      likes: 0,
      comments: 0,
      isLiked: false,
      isSaved: false,
      pollEndsAt: DateTime(2026),
      pollOptions: const [
        PollOption(id: 'yes', label: 'Yes', votes: 5, voted: false),
        PollOption(id: 'no', label: 'No', votes: 3, voted: false),
        PollOption(id: 'neutral', label: 'Neutral', votes: 2, voted: false),
      ],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: SocialPostAttachment(post: post)),
      ),
    ));

    expect(find.text('POLL RESULTS'), findsOneWidget);
    expect(find.text('Which song should we arrange next?'), findsOneWidget);
    expect(find.text('Created by Jose'), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.text('30.0%'), findsOneWidget);
    expect(find.text('20.0%'), findsOneWidget);
    expect(find.text('10 people voted'), findsOneWidget);
    expect(find.text('Ended'), findsOneWidget);
    final backgrounds = tester.widgetList<Container>(find.byType(Container))
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .map((decoration) => decoration.color);
    expect(backgrounds, isNot(contains(const Color(0xFF292929))));
    expect(tester.widget<Text>(find.text('Which song should we arrange next?'))
        .style?.color, isNot(Colors.white));
    expect(tester.takeException(), isNull);
  });
}
