# LenDen app (Flutter)

One Flutter codebase, four experiences. The screen you see depends on who logs in:

| Role | Experience | Best on |
|---|---|---|
| **Visitor / Borrower** | Landing page → readiness check (🟢🟡🔴) → "what you can change" tips with one-tap *Try it* → affordability → apply to a lender with consent → track status and lender messages · EMI calculator | Phone |
| **Loan officer** | Risk-sorted application queue (filters, sort) → application detail with model recommendation, reasons and inputs → Approve / Ask for documents / Reject with a note · Dashboard | Tablet / web |
| **Lender admin** | Everything officers have, plus: dashboard (KPIs, readiness mix, 14-day trend, **fairness monitor**, **drift monitor**), decision rules (cost ratio, review cap), team management, activity log | Web |
| **Platform owner** | Platform totals, lender organisations (tenants) and plans, create / suspend lenders | Web |

On wide screens (900 px and up) staff get a SaaS-style **sidebar**; on phones a bottom navigation bar.

## Design system

`lib/core/theme.dart` defines everything visual in one place, following common patterns of
modern fintech/SaaS dashboards:

- **Palette:** deep-teal brand colour, neutral grey canvas, white cards with a 1 px border, and
  semantic colours used consistently: green = ready / approved, amber = borderline,
  red = high risk / rejected, blue = submitted, violet = documents needed
- **Typography:** Inter (via `google_fonts`), tight headings, muted secondary text
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

Visitors can run a readiness check **without an account**. They are asked to log in only when they apply.

### Android / iOS: allow HTTP to a local API

Only needed for local development. A deployed `https://` API needs nothing.

- **Android:** in `android/app/src/main/AndroidManifest.xml`, add
  `<uses-permission android:name="android.permission.INTERNET"/>` above `<application`, and
  `android:usesCleartextTraffic="true"` to the `<application>` tag.
- **iOS:** in `ios/Runner/Info.plist` add
  `<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>`.

### Server address

Tap the server icon on the welcome screen (or *Server settings* in the account menu):

| Running on | Address |
|---|---|
| Android emulator | `http://10.0.2.2:8000` (default) |
| iOS simulator / web / desktop | `http://localhost:8000` (default) |
| Real phone on the same Wi-Fi | `http://<computer's IP>:8000` |
| Deployed API | `https://...` |

## Tests

```bash
flutter test       # formatters, EMI maths, schema parsing, readiness and EMI screen widget tests
flutter analyze
```

## Code map

```
lib/
  main.dart                         theme + RoleRouter (picks the shell by role)
  core/  api.dart                   JSON client, bearer token, readable errors
         session.dart               login/register/logout, saved token, AppScope
         theme.dart                 design system: colours, spacing, component themes
         format.dart                money, %, dates, light and status styles
  models/field_spec.dart            form schema from /metadata
  widgets/ brand.dart               logo, page header, icon tile, greeting
           common.dart              Loader, error/retry, KPI card, badges, chips
           field_input.dart         slider / segmented / dropdown per field
           account_menu.dart        avatar menu (server settings, log out)
           risk_gauge.dart          circular probability gauge
  screens/
    welcome_screen.dart             public landing page
    server_screen.dart              API address
    auth/                           login (with demo chips), register
    borrower/                       home tabs, check, result + apply sheet, my applications, EMI
    staff/                          shell (sidebar/bottom bar), queue, detail, dashboard,
                                    decision rules, team, activity log
    superadmin/super_console.dart   tenants, plans, platform totals
```
