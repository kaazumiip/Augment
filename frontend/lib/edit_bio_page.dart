import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'social_service.dart';

class EditBioPage extends StatefulWidget {
  const EditBioPage({super.key, required this.initialBio});
  final String initialBio;

  @override
  State<EditBioPage> createState() => _EditBioPageState();
}

class _EditBioPageState extends State<EditBioPage> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialBio);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bio = _controller.text.trim();
      await SocialService.instance.updateBio(bio);
      if (mounted) Navigator.pop(context, bio);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save your bio. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        appBar: AppBar(
          backgroundColor: AppPalette.page(context),
          foregroundColor: AppPalette.text(context),
          elevation: 0,
          title: const Text('Edit bio',
              style: TextStyle(fontWeight: FontWeight.w800)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Tell people a little about your music.',
                  style: TextStyle(
                      color: AppPalette.muted(context), fontSize: 14)),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 5,
                maxLines: 7,
                maxLength: 160,
                style: TextStyle(color: AppPalette.text(context)),
                decoration: InputDecoration(
                  hintText: 'Singer, producer, songwriter...',
                  hintStyle: TextStyle(color: AppPalette.muted(context)),
                  filled: true,
                  fillColor: AppPalette.surface(context),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: AppPalette.border(context)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: AppPalette.border(context)),
                  ),
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFCA000A),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : const Text('Save bio',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            ]),
          ),
        ),
      );
}
