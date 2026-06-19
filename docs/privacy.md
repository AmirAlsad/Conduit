# Privacy Policy

_Last updated: 19 June 2026_

Conduit is a **bring-your-own-agent** voice calling app for iOS. It connects your
iPhone to a voice agent **you** run, and gets out of the way. This policy explains
what the app does and does not do with your information.

The short version: **Conduit has no backend of its own, no account, and no
analytics. The developer collects no data about you.** Everything the app handles
either stays on your device or travels only to the server **you** configure.

## No data collected by us

Conduit has no servers, no user accounts, no analytics SDK, no advertising, and no
crash-reporting service. We — the developer — receive **nothing** about you or your
usage. The app phones home to nobody.

## Information the app handles, and where it goes

**Connection credentials.** The endpoint URLs, API keys, and tokens you enter to
reach your agent are stored in the iOS **Keychain** on your device. They never
leave your phone except to authenticate with the server you pointed the app at.

**Your voice during a call.** While a call is connected, microphone audio is sent
in real time, over an encrypted WebRTC connection, **only** to the agent endpoint
you configured. Conduit does not record, store, or copy your call audio, and does
not route it to the developer or any third party of ours.

**Call history.** Your list of recent calls (who, when, outcome) is stored locally
on your device. It is not uploaded anywhere. Deleting a call, or the app, removes it.

**Contacts (optional).** If you choose to add an agent to your Contacts, Conduit
writes and keeps in sync **that one contact's** name and photo. It does not read,
upload, or modify your other contacts, and it requests Contacts access only when
you use that feature.

**Siri (optional).** If you enable Siri, your agents' names are made available to
Siri on your device so you can say "call &lt;agent&gt;". This is handled by iOS on
your device.

**Local network (optional).** If your agent runs on your own computer on the same
Wi-Fi network, iOS will ask permission for Conduit to connect to it directly. This
connection stays on your local network.

## Third parties

The server you connect to — your own backend, and the real-time transport it uses
(for example a Daily or LiveKit room, or a direct connection to your machine) — is
operated by **you or whoever you chose**. Their handling of your audio is governed
by their terms, not ours. Choose endpoints you trust.

Conduit includes no third-party analytics, advertising, attribution, or tracking
libraries. The app does not track you across other apps or websites.

## Data security

Credentials are held in the iOS Keychain. Call audio is carried over encrypted
WebRTC (DTLS-SRTP) and standard TLS. Because there is no Conduit account or cloud
service, there is no central store of your data for anyone to breach.

## Children

Conduit is not directed at children and collects no personal information from
anyone, including children.

## Changes to this policy

If this policy changes, the updated version will be posted on this page with a new
"last updated" date.

## Contact

Conduit is open source. Questions or concerns can be raised on the project's
repository: [github.com/AmirAlsad/Conduit](https://github.com/AmirAlsad/Conduit/issues).
