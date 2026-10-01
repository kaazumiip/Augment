import 'package:flutter/material.dart';

import 'choose_tuner_instrument_page.dart';
import 'tuner_page.dart';

/// Keeps the older sheet entry point on the same real microphone tuner.
class TunerSheet extends StatelessWidget {
  const TunerSheet({super.key});

  @override
  Widget build(BuildContext context) => TunerPage(
        instrument: ChooseTunerInstrumentPage.instruments.first,
      );
}
