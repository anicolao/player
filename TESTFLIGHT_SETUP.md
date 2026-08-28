# TestFlight developer handoff and release configuration

This is the one-time Apple Developer Program setup required before the release
automation can sign, upload, and distribute Bookshelf builds without pausing for
credentials or two-factor authentication. Once the local handoff is installed,
the same configuration is reused for later builds until its API key is rotated
or revoked.

The repository is already configured for these identifiers:

- App: `com.spnss.player`
- Share extension: `com.spnss.player.share`
- Shared app group: `group.com.spnss.player`

Do not choose different identifiers in Apple's portals. If one is unavailable
and does not already belong to your team, stop and report that conflict so the
repository can be changed consistently.

## Security boundary

Never paste any of the following into chat, an issue, a pull request, or a Git
commit:

- the contents of an `AuthKey_*.p8` file;
- your Apple Account password or a two-factor authentication code;
- signing-certificate private keys;
- provisioning profiles.

The Team ID, API Key ID, API Issuer ID, bundle IDs, app name, and SKU are
identifiers rather than secrets. The helper below stores them outside the
repository anyway. The downloaded `.p8` file is the only secret in this
handoff.

The bootstrap credential is an **Admin team API key**. Admin is broad access,
but it permits unattended automatic signing as well as App Store Connect upload
and TestFlight management. Team keys apply across the account and cannot be
limited to one app. Keep it installed only as long as unattended signing needs
it; rotate or revoke it when this release train is complete. A narrower App
Manager key can handle later App Store Connect operations once signing assets
exist, but changing roles must be verified before removing the working key.

## One-time manual checklist

### 1. Confirm the account is ready

1. Sign in at <https://developer.apple.com/account>.
2. Confirm the Apple Developer Program membership is active.
3. Record the 10-character **Team ID** shown in Membership details.
4. Sign in at <https://appstoreconnect.apple.com>.
5. Open **Business** and accept any pending agreement. Apple will not allow an
   app record to be created until the Account Holder accepts the latest
   agreement.

No banking or tax setup is required merely to distribute a free internal
TestFlight build.

### 2. Register the identifiers and shared app group

In **Certificates, Identifiers & Profiles** at
<https://developer.apple.com/account/resources/identifiers/list>, create or
verify these two explicit App IDs:

- `Audiobook Bookshelf` — `com.spnss.player`
- `Audiobook Bookshelf Share Extension` — `com.spnss.player.share`

For each one, choose **App IDs → App**, **Explicit**, and leave unrelated
capabilities unchanged. The primary App ID must exist before the App Store
Connect app record can be created.

Next, return to the Identifiers list, click add (`+`), choose **App Groups**,
and register:

- Description: `Bookshelf Shared Imports`
- Identifier: `group.com.spnss.player`

Finally, open each App ID, enable **App Groups**, click **Configure**, select
`group.com.spnss.player`, and save. Apple's current public API can register App
IDs and enable the `APP_GROUPS` capability, but it exposes no named App Group
resource or membership relationship. Registering this group and selecting it
for both IDs therefore remain the only manual signing-resource steps.

Do not manually create certificates or provisioning profiles; deployment
automation manages those.

### 3. Create the App Store Connect app record

In **App Store Connect → Apps**, click the add button and choose **New App**.
Use:

- Platforms: **iOS**
- Name: **Bookshelf Offline Audio Player** (if unavailable, choose the final name you want and record
  it for the helper)
- Primary language: **English (Canada)**, or your preferred English locale
- Bundle ID: `com.spnss.player`
- SKU: `player-ios` (if already used in your account, use a unique variant and
  record it)
- User Access: **Full Access**

Create the record. Store-listing text and screenshots are not required for the
first internal TestFlight upload.

### 4. Generate the temporary API key

In **App Store Connect → Users and Access → Integrations → App Store Connect
API**:

1. If API access has not been enabled, the Account Holder must click **Request
   Access**, accept the terms, and wait for Apple to approve the request. Stop
   here if approval is pending.
2. Open **Team Keys** and click **Generate API Key** (`+`).
3. Name: `Bookshelf TestFlight Bootstrap` (or another name that clearly identifies
   this repository's automation key)
4. Access: **Admin**
5. Generate and download the key. Apple permits the private key to be
   downloaded only once.
6. Record the **Issuer ID** and **Key ID** shown on this page.

Leave the downloaded `AuthKey_<KEY_ID>.p8` file intact. Do not open it or paste
its contents anywhere.

### 5. Install the handoff locally

From the repository root, run:

```bash
apps/ios/scripts/configure-testflight-handoff.sh
```

The helper asks for:

- Team ID;
- API Issuer ID;
- API Key ID;
- the downloaded `.p8` path;
- the exact App Store Connect name and SKU;
- the email of an existing App Store Connect user who should receive the
  internal TestFlight builds.

It moves the key to the private location searched by Apple's upload tool:

```text
~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
```

It writes non-secret deployment configuration with owner-only permissions to:

```text
~/.config/player/testflight.env
```

Neither path is inside the repository. The helper validates identifier formats
and confirms that the file is a parseable private key without printing it.

### 6. Hand control back to Codex

Reply only:

```text
Developer handoff complete.
```

Do not include IDs or credentials in the reply. Codex will read the local
configuration, verify API access without exposing the key, and then handle the
remaining work: repository recovery, local tests, CI, branch publication,
automatic signing, archive validation, monotonically increasing build uploads,
processing checks, and internal TestFlight assignment.

## Conditions that still require a report

Report the exact on-screen error, but no secrets, if:

- an identifier is owned by another team;
- the App Group cannot be registered or selected for both App IDs;
- `Bookshelf Offline Audio Player` is unavailable as an App Store Connect name;
- API access is pending or denied;
- the app record cannot be created;
- your intended tester is not an App Store Connect user.

## Releasing later builds

Do not repeat the portal checklist. Leave the private key and
`~/.config/player/testflight.env` in place and hand control to Codex. The release
process supplies the next build number while archiving, validates the signed
archive, uploads it, and checks distribution. A release is complete only after
App Store Connect reports the build `VALID` and the configured internal group
reports `IN_BETA_TESTING`.

When unattended releases are no longer needed, revoke the installed automation
key under **Users and Access → Integrations → Team Keys**, then remove its local
`.p8` file. Revocation is permanent and does not remove uploaded builds or
signing assets. Do not revoke or delete the only working key in the middle of an
active release train.

## Apple references

- [App Store Connect API access and API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)
- [Register an App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id)
- [Register an app group](https://developer.apple.com/help/account/identifiers/register-an-app-group)
- [Manage Bundle ID capabilities with the API](https://developer.apple.com/documentation/appstoreconnectapi/bundle-id-capabilities)
- [Add a new app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
- [Apple Developer Program role permissions](https://developer.apple.com/help/account/access/roles)
- [Add internal TestFlight testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
