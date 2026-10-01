# App Store review notes

## App Transport Security

Cassette is a client for user-configured Subsonic and OpenSubsonic music
servers. Those servers can be hosted on a local network or on a private network
without a DNS name, so their host names cannot be listed as static ATS exception
domains in the app bundle.

The app prefers HTTPS and prominently warns when a user enters an `http://`
address. Before sending credentials over HTTP, it presents a second confirmation
that explains the server address, username, password, and music traffic can be
observed on the network. HTTP access is never selected by the app and is only
used for the exact server URL entered by the user.

For that core self-hosted-server use case, `NSAllowsArbitraryLoads` remains
enabled. All built-in third-party integrations use HTTPS.

## Optional lyric translation

Apple Translation uses the system translation framework. If the user explicitly
selects OpenAI Translation, Cassette discloses in Settings that the lyric text is
sent to OpenAI and that API inputs and outputs may be retained for up to 30 days
for abuse monitoring. The user's OpenAI API key is kept in Keychain, and
translation results are cached locally to avoid repeat requests.

## Privacy manifest

The app and widget include `PrivacyInfo.xcprivacy`. UserDefaults stores app and
App Group preferences; file metadata is read only for files in Cassette's own
containers to manage caches and downloads. The app conservatively declares lyric
text sent through optional OpenAI Translation as linked Other User Content used
for app functionality. Cassette contains no advertising, tracking, or analytics
SDK.
