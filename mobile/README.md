# LenDen app (Flutter)

One Flutter codebase for web and Android, in **English and Bangla**. What you see depends on who logs in.

| Role | Experience | Best on |
|---|---|---|
| **Visitor / Borrower** | Landing page → 4-step check with autosave (no account needed) → approval odds, instalment and the smallest change that would help → live simulator → offers from every lender → apply with consent → status timeline, document upload, inbox → loan schedule, payments, credit level | Phone |
| **Loan officer** | Queue with filters (status, mine/unassigned, odds), sorting by risk or SLA → claim → reasons, counterfactual, similar decisions, shadow score, documents, timeline → approve with terms, request documents, decline with reason codes · Dashboard · Portfolio | Tablet / web |
| **Lender admin** | Everything officers have, plus decision settings (cost ratio, review cap, SLA), offer rules and ladder caps, team, activity log, fairness details | Web |
| **Platform owner** | Funnel and drop-off, lenders, model registry (candidate → shadow → active, comparison report), feature flags, background jobs | Web |

## Code layout

```
lib/
  app/        app.dart (MaterialApp.router, locales), router.dart (go_router, role-based redirects)
  core/       api/ (client: refresh tokens, draft token, idempotency, uploads), auth/ (session, locale),
              l10n/ (strings_en.dart, strings_bn.dart, generated), theme/, format.dart (Taka, Bangla digits)
  shared/     models/ (metadata), widgets/ (odds, offers, explanations, timeline, field inputs, common)
  features/   onboarding · auth · readiness (wizard, simulator) · offers · applications · loans ·
              notifications · account · borrower · staff · platform
tool/strings.py   source of all strings in both languages: edit it, then run `python tool/strings.py`
```

State lives in Riverpod providers; each screen loads its data through a `FutureProvider` and
refreshes with `ref.invalidate`. The API only sends codes (statuses, reason codes, errors); the app
translates them, so changing the language never needs a server change.

## Design system

`lib/core/theme/theme.dart` defines everything visual in one place, following common patterns of
modern fintech/SaaS dashboards:

- **Palette:** deep-teal brand colour, neutral grey canvas, white cards with a 1 px border, and
  semantic colours used consistently: green = ready / approved, amber = borderline,
  red = high risk / rejected, blue = submitted, violet = documents needed
- **Typography:** Inter for English and Hind Siliguri for Bangla (via `google_fonts`)
- **Components:** flat outlined cards (radius 14), filled inputs, 48 px buttons, floating
  snackbars, rounded dialogs and sheets, tinted icon tiles, KPI cards
- **Light and dark mode** follow the device setting

## Run it

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install) **3.29 or newer**.

```bash
# 1. Start the API from the project root (creates demo data on first run)
uvicorn api.main:app --host 0.0.0.0 --port 8000

# 2. Generate platform folders (once; this repo ships lib/ and test/ only)
cd mobile
flutter create --org com.lenden --platforms=android,ios,web .

# 3. Run on a phone/emulator, or in Chrome for the staff panels
flutter pub get
flutter run                 # phone / emulator
flutter run -d chrome       # web (best for officer and admin panels)
```

### Demo accounts (password `demo1234`)

The login screen has one-tap chips for these:

| Role | Email |
|---|---|
| Borrower | `borrower1@demo.app` (up to `borrower200@demo.app`) |
| Loan officer | `mahmud@greenfield.demo`, `sharmin@greenfield.demo`, `rina@riverside.demo` |
| Lender admin | `admin@greenfield.demo`, `admin@riverside.demo` |
| Platform owner | `super@lenden.app` |

Visitors can run the whole check **without an account**; their answers carry over when they sign up.
Demo borrowers can also log in by mobile number (`01700000001` for borrower 1, `01700000002` for
borrower 2, ...): the demo shows the one-time code on screen.

### Android / iOS: allow HTTP to a local API

Only needed for local development. A deployed `https://` API needs nothing.

- **Android:** in `android/app/src/main/AndroidManifest.xml`, add
  `<uses-permission android:name="android.permission.INTERNET"/>` above `<application`, and
  `android:usesCleartextTraffic="true"` to the `<application>` tag.
- **iOS:** in `ios/Runner/Info.plist` add
  `<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>`.

### Server address

Tap the server icon on the login screen (or *Server* in Account):

| Running on | Address |
|---|---|
| Android emulator | `http://10.0.2.2:8000` (default) |
| iOS simulator / web / desktop | `http://localhost:8000` (default) |
| Real phone on the same Wi-Fi | `http://<computer's IP>:8000` |
| Deployed API | `https://...` |

## Tests

```bash
flutter test       # formatters (Taka, Bangla digits), strings, schema parsing, welcome and odds widgets
flutter analyze
```

Add a string: put it in `tool/strings.py` (both languages), run `python tool/strings.py`, and use it
with `context.t('your.key')`.
