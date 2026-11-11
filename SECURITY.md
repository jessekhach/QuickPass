# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately through GitHub: open the **Security** tab of this repository and choose **Report a vulnerability**. Reports are reviewed as soon as possible, and reporters are credited in the fix unless they prefer otherwise.

## Supported versions

Security fixes are released for the latest version only.

## Data handling

| Data | Where it lives | How long |
| --- | --- | --- |
| Titles and usernames | `~/Library/Application Support/QuickPass/logins.json`, readable only by the current user | Until the next refresh from Passwords |
| Websites | `~/Library/Application Support/QuickPass/websites.json`, readable only by the current user | Until QuickPass is removed |
| Website icons | `~/Library/Caches/com.jkcreativestudios.quickpass/Icons` | Until macOS clears caches |
| Passwords and verification codes | Memory only, never written to disk | Up to two minutes after use, configurable in Settings |
| Copied passwords and codes | The clipboard, marked as concealed so clipboard managers skip them | Cleared after 60 seconds by default, configurable in Settings |
| Generated passwords | Memory and the clipboard, until saved to Passwords or discarded | Same as copied passwords |

QuickPass sends synthetic keystrokes in two cases only: filling Passwords' New Password form when saving a login, and filling the previous app when ⌘↩ or ⌥⌘↩ is pressed. When saving a login, the password is pasted into the form through the clipboard, marked as concealed, and the previous clipboard contents are restored afterwards.

## Network access

QuickPass makes two kinds of network request on its own. The daily update check reads `appcast.xml` from this repository. Website icons are fetched from each login's own site, without cookies, and never from an icon service, so no third party learns which sites you have logins for. Icons can be turned off in Settings. Updates are signed with an EdDSA key, and Sparkle rejects any download whose signature does not match, in addition to Apple's notarization checks.
