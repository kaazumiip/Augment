class BandPart {
  const BandPart({
    required this.id,
    required this.instrument,
    required this.role,
    this.displayName,
  });

  final String id;
  final String instrument;
  final String role;
  final String? displayName;

  static const roles = ['melody', 'harmony', 'bass', 'drums'];

  static List<String> rolesForInstrument(String instrument) =>
      instrument == 'Drums'
          ? const ['drums']
          : const ['melody', 'harmony', 'bass'];

  BandPart normalizedForInstrument() {
    if (instrument == 'Drums') return copyWith(role: 'drums');
    if (role == 'drums') return copyWith(role: 'harmony');
    return this;
  }

  String get roleLabel => switch (role) {
        'melody' => 'Lead',
        'harmony' => 'Harmony',
        'bass' => 'Bass',
        'drums' => 'Rhythm',
        _ => role,
      };

  BandPart copyWith({String? instrument, String? role, String? displayName}) =>
      BandPart(
        id: id,
        instrument: instrument ?? this.instrument,
        role: role ?? this.role,
        displayName: displayName ?? this.displayName,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'instrument': instrument,
        'role': role,
        'display_name': displayName ?? instrument,
      };
}
