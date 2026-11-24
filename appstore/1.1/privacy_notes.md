# SP500 Heatmap 1.1 - privacy notes (for App Privacy answers)

## What the app and server handle
- No accounts, no sign-in, no tracking, no advertising, no analytics or third-party SDKs.
- Portfolio, watchlists and settings: stored on the device and, if the user has iCloud, in the user's own iCloud (iCloud key-value storage). We have no access to them.
- Push notifications (optional): the app sends to our server an APNs device token, the interface language, the time zone and the alert rules the user created (symbols, thresholds, summary time). Used only to deliver alerts. Not linked to a name, email or any account, not shared with third parties, not used for tracking.
- Calendar: write-only access (add earnings and dividend events). The app reads no calendar data.
- Market data requests go to our server and to data providers (Yahoo Finance, Finnhub, CoinGecko) and contain no personal data. Standard server logs may hold IP addresses for a short time for operation and abuse protection.
- AI features run on the device (Apple FoundationModels); chat text does not leave the device.

## Suggested App Privacy answers in App Store Connect
- Data used to track you: No. Tracking: none.
- Data collected: Yes, one type only.
  - Identifiers > Device ID (the APNs push token): collected, used for App Functionality, NOT linked to the user's identity, NOT used for tracking.
  - Everything else (contact info, health, financial info, location, contacts, user content, browsing history, search history, usage data, diagnostics): Not collected. Portfolio data stays on device and in the user's iCloud, so "Financial Info" is not collected by us.
- Privacy policy URL: use the existing one in the listing.
- Age rating: no restricted content; mention of investing is informational. Not a financial service (no trading, no payments).
- Export compliance: only standard HTTPS encryption (exempt).
