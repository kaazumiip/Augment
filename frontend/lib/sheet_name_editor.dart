import 'package:flutter/material.dart';

import 'app_palette.dart';

/// Small, phone-first rename sheet that follows Augment's cream/red surface
/// language instead of using the platform's plain alert dialog.
Future<String?> showSheetNameEditor(
  BuildContext context, {
  required String currentName,
}) async {
  final result = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => _SheetNameEditorSheet(currentName: currentName),
  );
  return result?.trim().isEmpty == true ? null : result?.trim();
}

Future<bool> showSheetDeleteEditor(
  BuildContext context, {
  required String sheetName,
}) async {
  return await showModalBottomSheet<bool>(
        context: context,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => Material(
          color: AppPalette.page(sheetContext),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                height: 4,
                width: 42,
                decoration: BoxDecoration(
                  color: AppPalette.border(sheetContext),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFE4E1),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: const Icon(Icons.delete_outline_rounded,
                    color: Color(0xFFCA000A), size: 27),
              ),
              const SizedBox(height: 13),
              Text('Delete this sheet?',
                  style: TextStyle(
                    color: AppPalette.text(sheetContext),
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  )),
              const SizedBox(height: 7),
              Text(
                '“$sheetName” will be removed from My sheets and its saved files will be cleared.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppPalette.muted(sheetContext), height: 1.35),
              ),
              const SizedBox(height: 22),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(sheetContext, false),
                    child: const Text('Keep sheet'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFCA000A),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => Navigator.pop(sheetContext, true),
                    icon: const Icon(Icons.delete_rounded),
                    label: const Text('Delete'),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ) ??
      false;
}

void showSheetNotice(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.fromLTRB(
          16, 0, 16, 20 + MediaQuery.paddingOf(context).bottom),
      backgroundColor: const Color(0xFF201E1D),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: Row(children: [
        const Icon(Icons.check_circle_rounded, color: Color(0xFFFF625C)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ]),
    ));
}

class _SheetNameEditorSheet extends StatefulWidget {
  const _SheetNameEditorSheet({required this.currentName});

  final String currentName;

  @override
  State<_SheetNameEditorSheet> createState() => _SheetNameEditorSheetState();
}

class _SheetNameEditorSheetState extends State<_SheetNameEditorSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.currentName);

  void _close([String? name]) {
    // Explicitly clear the field's focus before its modal route deactivates.
    // This avoids the framework dependent-element assertion seen on Android
    // when Save is tapped with the keyboard still open.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(name?.trim());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext sheetContext) => Material(
        color: AppPalette.page(sheetContext),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            10,
            20,
            20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              height: 4,
              width: 42,
              decoration: BoxDecoration(
                color: AppPalette.border(sheetContext),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFFCA000A),
                borderRadius: BorderRadius.circular(17),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x33CA000A),
                      blurRadius: 18,
                      offset: Offset(0, 8)),
                ],
              ),
              child: const Icon(Icons.drive_file_rename_outline_rounded,
                  color: Colors.white, size: 27),
            ),
            const SizedBox(height: 13),
            Text('Name your sheet',
                style: TextStyle(
                  color: AppPalette.text(sheetContext),
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                )),
            const SizedBox(height: 5),
            Text('This name is used in My sheets.',
                style: TextStyle(color: AppPalette.muted(sheetContext))),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 60,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: _close,
              decoration: InputDecoration(
                labelText: 'Sheet name',
                hintText: 'e.g. Moonlight practice',
                prefixIcon: const Icon(Icons.music_note_rounded),
                filled: true,
                fillColor: AppPalette.isDark(sheetContext)
                    ? const Color(0xFF292424)
                    : const Color(0xFFFFF6F3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide:
                      BorderSide(color: AppPalette.border(sheetContext)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide:
                      BorderSide(color: AppPalette.border(sheetContext)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide:
                      const BorderSide(color: Color(0xFFCA000A), width: 2),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _close,
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFCA000A),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => _close(_controller.text),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Save name'),
                ),
              ),
            ]),
          ]),
        ),
      );
}
