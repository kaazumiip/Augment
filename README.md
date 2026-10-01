# Augment

## App API configuration

Debugging on a USB-connected Android device uses `adb reverse` and defaults to
`http://127.0.0.1:3000`. The Android emulator also falls back to
`http://10.0.2.2:3000`.

Release builds must provide the hosted API URL:

```powershell
flutter build apk --release --dart-define=AUGMENT_API_URL=https://api.example.com
```

The value must be the Node API origin without a trailing slash.

## Database migrations

The authoritative, ordered migrations are in `supabase/migrations`. For a new
Supabase project, link the project and apply them with:

```powershell
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

Existing projects that previously ran the loose SQL scripts should first use
`supabase migration list` and baseline the matching migrations before `db push`.
Do not rerun files from `database/` after moving to the migration workflow.

The final migration creates the `sheet-assets` bucket used to keep generated
MusicXML, PDF, audio, and preview images available after reinstalling the app.
