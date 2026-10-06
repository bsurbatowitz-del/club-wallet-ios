# Club Wallet for iPhone

The iPhone version of the Ubuntu **Club Wallet Cards** app. It reads your member list, makes Apple Wallet
and Google Wallet membership cards with a QR code (registration number, name, surname, email), the
background picture and member photos, and emails every member their card through Gmail. It also lets you
**add a card to Apple Wallet on your own iPhone** for testing.

Requires iOS 18 or newer. No Mac needed: GitHub builds the app on its Macs and sends it to **TestFlight**,
and you install it from the TestFlight app.

## How it gets onto your iPhone

```
push to GitHub ─▶ GitHub Actions (macOS): tests + build ─▶ signed & uploaded to App Store Connect ─▶ TestFlight app on your iPhone
```

### One-time setup

**Easiest:** on Ubuntu run `club-wallet-cards-apple-setup` (from Club Wallet Cards 1.4). After you create
an App Store Connect API key in the browser, it registers the App ID, sets this repository's secrets and
variables, starts the build and adds you as a TestFlight tester. The only other browser step is
creating the app record (step 2). The manual steps are below.

You need the paid Apple Developer account (the same one used for Wallet passes).

1. **Register the app's ID** at [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list)
   → Identifiers → **+** → *App IDs* → *App*.
   Description `Club Wallet`, Bundle ID **Explicit**, e.g. `com.yourclub.clubwallet`. No capabilities needed → Register.
2. **Create the app record** in [App Store Connect](https://appstoreconnect.apple.com/apps) → **+** → *New App*:
   platform iOS, a name (must be unique on the App Store, e.g. `Triatlon Klub Budva Cards`),
   language, the Bundle ID from step 1, SKU `clubwallet`. It stays private – TestFlight only.
3. **Make an API key for GitHub**: App Store Connect → *Users and Access* → *Integrations* →
   *App Store Connect API* → *Team Keys* → **+**. Name `GitHub`, access **Admin**
   (needed so GitHub can create the signing certificate in the cloud). Download the `.p8` file
   (only possible once!) and note the **Key ID** and the **Issuer ID** shown above the list.
4. Find your **Team ID**: developer.apple.com → Account → *Membership details*.
5. In this GitHub repository: **Settings → Secrets and variables → Actions**
   - *Secrets* tab → **New repository secret**, three times:
     - `ASC_KEY_ID` – the Key ID
     - `ASC_ISSUER_ID` – the Issuer ID
     - `ASC_KEY_P8` – open the .p8 file in a text editor and paste everything, including the BEGIN/END lines
   - *Variables* tab → **New repository variable**, three times:
     - `BUNDLE_ID` – e.g. `com.yourclub.clubwallet` (same as step 1)
     - `TEAM_ID` – your 10-character Team ID
     - `TESTFLIGHT` – `true`
6. **Build**: *Actions* tab → *iOS* → **Run workflow** (or push any change). After ~15 minutes the
   *Upload to TestFlight* job is green; Apple then processes the build for 5–30 minutes.
7. **Install**: App Store Connect → your app → *TestFlight* → *Internal Testing* → **+** create a group,
   add yourself as a tester. On the iPhone install **TestFlight** from the App Store, sign in with
   the same Apple ID and install *Club Wallet*.

TestFlight builds work for 90 days; run the workflow again for a fresh one. Every push to `main` makes a new build.

## Moving your setup from Ubuntu

In the Ubuntu app: **File → Export for iPhone app…** It saves one `.clubwallet` file with all settings,
the Apple certificate/key, the Google key, logo, background, member list and member photos.
Protect it with a password, send it to yourself (email/Google Drive/iCloud), then on the iPhone either
tap it in the Files app → *Share* → *Club Wallet*, or open Club Wallet → **Settings → Import from Ubuntu app**.

## Using the app

- **Members**: import the list (or it comes with the transfer file). Tap a member to see the card, choose
  their photo from your photo library, **Add to Apple Wallet on this iPhone**, open their Google link, or email them.
  *Select* lets you pick several members to make or email cards; the ⋯ menu does everyone. People already
  emailed are marked with ✓ and can be skipped.
- **Design**: club name, season, colours (or taken from the background picture), logo, background, member
  photos (import a folder of photos from Files; matched by file name like on Ubuntu), QR content, preview.
- **Wallets**: Apple certificate files and layout (Banner / Full background / Classic), Google Wallet issuer and key.
- **Email**: Gmail (smtp.gmail.com, port 465, SSL/TLS) with an App password. Send yourself a test first.
- **Settings**: transfer-file import, export/import settings as JSON (with or without passwords), reset.
  Generated cards are in the Files app → On My iPhone → Club Wallet → Cards.

Settings and keys stay inside the app's private storage on the phone.

## For developers

- `Sources/ClubCore` – platform-independent logic: CMS/PKCS#7 signing of passes, zip, .ods/.xlsx/.csv reading,
  Google Wallet REST + JWT, MIME + SMTP, transfer-file decryption. No third-party dependencies.
- `Tests/ClubCoreTests` – run with `swift test` on macOS; signatures are verified with `openssl`, emails with Python's parser.
- `App/` – SwiftUI app; `project.yml` – [XcodeGen](https://github.com/yonaskolb/XcodeGen) project (`xcodegen generate`).
- `.github/workflows/ios.yml` – tests, simulator build, and (when `TESTFLIGHT=true`) unsigned archive →
  signed export with automatic cloud signing → upload.
