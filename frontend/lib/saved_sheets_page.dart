import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'generated_sheets_store.dart';
import 'music_sheet_page.dart';
import 'sheet_name_editor.dart';

class SavedSheetsPage extends StatelessWidget {
  const SavedSheetsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final isSmallPhone = screen.width < 430 || screen.height < 620;
    final horizontalPadding = isSmallPhone ? 14.0 : 26.0;
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              horizontalPadding, isSmallPhone ? 12 : 16, horizontalPadding, 0),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('My',
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: isSmallPhone ? 38 : 44,
                    height: .86,
                    letterSpacing: -1.8,
                    fontWeight: FontWeight.w900)),
            Text('sheets',
                style: TextStyle(
                    color: const Color(0xFFCA000A),
                    fontSize: isSmallPhone ? 38 : 44,
                    height: .92,
                    letterSpacing: -1.8,
                    fontWeight: FontWeight.w900)),
            SizedBox(height: isSmallPhone ? 8 : 11),
            Text('Your generated music sheets',
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 13)),
            SizedBox(height: isSmallPhone ? 14 : 22),
            Expanded(
              child: FutureBuilder(
                future: GeneratedSheetsStore.instance.loadLocal(),
                builder: (_, __) => ListenableBuilder(
                  listenable: GeneratedSheetsStore.instance,
                  builder: (context, _) {
                    final sheets = GeneratedSheetsStore.instance.sheets;
                    if (sheets.isEmpty) {
                      return Center(
                          child: Text('No generated sheets yet.',
                              style:
                                  TextStyle(color: AppPalette.muted(context))));
                    }
                    return LayoutBuilder(builder: (context, constraints) {
                      final grouped = <String, List<SavedSheet>>{};
                      for (final sheet in sheets) {
                        grouped
                            .putIfAbsent(sheet.instrument, () => [])
                            .add(sheet);
                      }
                      final groups = grouped.entries.toList()
                        ..sort((a, b) => b.value.first.createdAt
                            .compareTo(a.value.first.createdAt));
                      return GridView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.only(
                          bottom: 124 + MediaQuery.paddingOf(context).bottom,
                        ),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: constraints.maxWidth >= 680 ? 2 : 1,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          mainAxisExtent: 124,
                        ),
                        itemCount: groups.length,
                        itemBuilder: (context, index) {
                          final group = groups[index];
                          return _InstrumentFolderCard(
                            instrument: group.key,
                            count: group.value.length,
                            latest: group.value.first.createdAt,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _InstrumentSheetsPage(
                                  instrument: group.key,
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    });
                  },
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _InstrumentFolderCard extends StatelessWidget {
  const _InstrumentFolderCard({
    required this.instrument,
    required this.count,
    required this.latest,
    required this.onTap,
  });
  final String instrument;
  final int count;
  final DateTime latest;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF980400), Color(0xFFE01B12)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: .16)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .035),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Stack(children: [
              Positioned(
                left: 0,
                top: 4,
                bottom: 4,
                child: Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text('SHEET LIBRARY',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: .8),
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.05)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .16),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('$count ${count == 1 ? 'sheet' : 'sheets'}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800)),
                      ),
                    ]),
                    const Spacer(),
                    Text(instrument,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            height: 1,
                            fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Text('Latest ${_folderDate(latest)}',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: .78),
                              fontSize: 11)),
                      const Spacer(),
                      const Text('Open folder',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(width: 5),
                      const Text('→',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              height: .8,
                              fontWeight: FontWeight.w700)),
                    ]),
                  ],
                ),
              ),
            ]),
          ),
        ),
      );
}

/* Retired icon-based cover design. Folder cards intentionally use no icon. */
/*
class _InstrumentSheetCover extends StatelessWidget {
  const _InstrumentSheetCover({required this.monogram});
  final String monogram;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 62,
        height: 76,
        child: Stack(children: [
          Positioned(
            left: 8,
            top: 5,
            child: Container(
              width: 50,
              height: 66,
              decoration: BoxDecoration(
                color: const Color(0xFFCA000A).withValues(alpha: .13),
                borderRadius: BorderRadius.circular(13),
              ),
            ),
          ),
          Container(
            width: 50,
            height: 66,
            padding: const EdgeInsets.fromLTRB(9, 8, 7, 7),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF9F7),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                  color: const Color(0xFFCA000A).withValues(alpha: .18)),
            ),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(monogram,
                  style: const TextStyle(
                      color: Color(0xFFCA000A),
                      fontSize: 20,
                      height: .9,
                      fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              for (var index = 0; index < 4; index++)
                Container(
                  height: 1,
                  margin: const EdgeInsets.only(bottom: 3),
                  color: const Color(0xFFCA000A).withValues(alpha: .28),
                ),
              const Align(
                alignment: Alignment.centerRight,
                child: Text('♪',
                    style: TextStyle(
                        color: Color(0xFFCA000A),
                        fontSize: 14,
                        fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
        ]),
      );
}

*/
String _folderDate(DateTime time) =>
    '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}.${time.year}';

class _InstrumentSheetsPage extends StatelessWidget {
  const _InstrumentSheetsPage({required this.instrument});
  final String instrument;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: ListenableBuilder(
          listenable: GeneratedSheetsStore.instance,
          builder: (context, _) {
            final sheets = GeneratedSheetsStore.instance.sheets
                .where((sheet) => sheet.instrument == instrument)
                .toList();
            return ListView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                  26, 14, 26, 32 + MediaQuery.paddingOf(context).bottom),
              children: [
                Row(children: [
                  AppBackButton(onPressed: () => Navigator.pop(context))
                ]),
                const SizedBox(height: 24),
                Text(instrument,
                    style: TextStyle(
                        color: AppPalette.text(context),
                        fontSize: 42,
                        height: .8,
                        letterSpacing: -2.5,
                        fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                const Text('sheets',
                    style: TextStyle(
                        color: Color(0xFFCA000A),
                        fontSize: 42,
                        height: .9,
                        letterSpacing: -2.5,
                        fontWeight: FontWeight.w900)),
                const SizedBox(height: 24),
                Container(
                    width: 100, height: 6, color: const Color(0xFFCA000A)),
                const SizedBox(height: 34),
                for (final sheet in sheets) ...[
                  _SavedSheetCard(
                    sheet: sheet,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MusicSheetPage(
                          instrumentName: sheet.instrument,
                          apiResult: sheet.result,
                          savedSheet: sheet,
                        ),
                      ),
                    ),
                    onRename: () => _renameSheet(context, sheet),
                    onDelete: () => _deleteSheet(context, sheet),
                  ),
                  const SizedBox(height: 22),
                ],
              ],
            );
          },
        ),
      );
}

Future<void> _deleteSheet(BuildContext context, SavedSheet sheet) async {
  final confirmed =
      await showSheetDeleteEditor(context, sheetName: sheet.title);
  if (confirmed) {
    await GeneratedSheetsStore.instance.delete(sheet);
    if (context.mounted) showSheetNotice(context, 'Sheet deleted');
  }
}

Future<void> _renameSheet(BuildContext context, SavedSheet sheet) async {
  final title = await showSheetNameEditor(context, currentName: sheet.title);
  if (title != null) {
    final renamed = await GeneratedSheetsStore.instance.rename(sheet, title);
    if (context.mounted) {
      showSheetNotice(
          context,
          renamed
              ? 'Sheet name updated'
              : 'Could not save the sheet name. Please try again.');
    }
  }
}

class _SavedSheetCard extends StatelessWidget {
  const _SavedSheetCard({
    required this.sheet,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final SavedSheet sheet;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final noteCount = (sheet.result['total_notes'] as num?)?.toInt();
    final tempo = (sheet.result['tempo'] as num?)?.round();
    final synced = sheet.result['remote_project_id'] != null;
    final assetsSaved = sheet.result['musicxml_url'] != null;
    final date =
        '${sheet.createdAt.day.toString().padLeft(2, '0')}.${sheet.createdAt.month.toString().padLeft(2, '0')}.${sheet.createdAt.year}';
    final hour =
        sheet.createdAt.hour % 12 == 0 ? 12 : sheet.createdAt.hour % 12;
    final time = '$hour:${sheet.createdAt.minute.toString().padLeft(2, '0')} '
        '${sheet.createdAt.hour >= 12 ? 'PM' : 'AM'}';

    return _PosterSheetCard(
      sheet: sheet,
      date: date,
      time: time,
      noteCount: noteCount,
      tempo: tempo,
      cloudSaved: synced && assetsSaved,
      onTap: onTap,
      onRename: onRename,
      onDelete: onDelete,
    );

    /* legacy compact-card layout retained only as source history.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(15, 13, 10, 13),
          decoration: BoxDecoration(
            color: AppPalette.page(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppPalette.border(context).withValues(
                alpha: AppPalette.isDark(context) ? .52 : .9,
              ),
            ),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: Color(0xFFCA000A),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.music_note_rounded,
                    color: Colors.white, size: 23),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sheet.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: textColor,
                              fontFamily: 'Instrument Sans',
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text('Generated $date · $time',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: muted,
                              fontFamily: 'Instrument Sans',
                              fontSize: 11)),
                    ]),
              ),
              IconButton(
                tooltip: 'Edit sheet name',
                onPressed: onRename,
                color: const Color(0xFFCA000A),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_rounded, size: 18),
              ),
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: Icon(Icons.more_horiz_rounded, color: muted, size: 21),
                ),
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete sheet',
                        style: TextStyle(color: Color(0xFFCA000A))),
                  )
                ],
              ),
            ]),
            const Spacer(),
            const SizedBox(height: 8),
            Divider(
              height: 1,
              color: AppPalette.border(context).withValues(alpha: .55),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _MetaPill(label: sheet.instrument),
              if (tempo != null) _MetaPill(label: '$tempo BPM'),
              if (noteCount != null) _MetaPill(label: '$noteCount notes'),
              _MetaPill(
                label: synced && assetsSaved ? 'Cloud saved' : 'Saved locally',
                neutral: !(synced && assetsSaved),
              ),
            ]),
          ]),
        ),
      ),
    );
    */
  }
}

class _PosterSheetCard extends StatelessWidget {
  const _PosterSheetCard({
    required this.sheet,
    required this.date,
    required this.time,
    required this.noteCount,
    required this.tempo,
    required this.cloudSaved,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final SavedSheet sheet;
  final String date;
  final String time;
  final int? noteCount;
  final int? tempo;
  final bool cloudSaved;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Ink(
            decoration: BoxDecoration(
              color: AppPalette.surface(context),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppPalette.border(context)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .055),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(23),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  height: 205,
                  child: Row(children: [
                    Expanded(
                      child: Container(
                        height: double.infinity,
                        padding: const EdgeInsets.fromLTRB(18, 10, 12, 16),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF970400), Color(0xFFE81A12)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Align(
                                alignment: Alignment.topRight,
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: 'Edit sheet name',
                                        onPressed: onRename,
                                        icon: const Icon(Icons.edit_rounded,
                                            color: Colors.white, size: 20),
                                      ),
                                      PopupMenuButton<String>(
                                        icon: const Icon(
                                            Icons.more_vert_rounded,
                                            color: Colors.white),
                                        onSelected: (value) {
                                          if (value == 'delete') onDelete();
                                        },
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'delete',
                                            child: Text('Delete sheet',
                                                style: TextStyle(
                                                    color: Color(0xFFCA000A))),
                                          ),
                                        ],
                                      ),
                                    ]),
                              ),
                              const Spacer(),
                              Text(sheet.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 31,
                                    height: .88,
                                    letterSpacing: -1.3,
                                    fontWeight: FontWeight.w900,
                                  )),
                              const SizedBox(height: 12),
                              Text('Generated $date · $time',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: .85),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  )),
                            ]),
                      ),
                    ),
                  ]),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Row(children: [
                    _PosterMeta(
                        top: sheet.instrument.toUpperCase(),
                        bottom: 'Instrument'),
                    _PosterDivider(),
                    _PosterMeta(
                        top: tempo == null ? '— BPM' : '$tempo BPM',
                        bottom: 'Tempo'),
                    _PosterDivider(),
                    _PosterMeta(
                        top: noteCount == null ? '— notes' : '$noteCount notes',
                        bottom: 'Total notes'),
                    _PosterDivider(),
                    _PosterMeta(
                        top: cloudSaved ? 'Cloud saved' : 'Saved locally',
                        bottom: 'Storage'),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _PosterMeta extends StatelessWidget {
  const _PosterMeta({required this.top, required this.bottom});
  final String top;
  final String bottom;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(top,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 3),
          Text(bottom,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(color: AppPalette.muted(context), fontSize: 9.5)),
        ]),
      );
}

class _PosterDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: AppPalette.border(context),
      );
}
