# Rounds

A native macOS app that pulls the most relevant threads and shared resources from a set of subreddits, stores them on your Mac, and makes them searchable offline.

- SwiftUI, Swift 6, macOS 14+
- SQLite through [GRDB](https://github.com/groue/GRDB.swift) with an FTS5 full-text index
- Read-only Reddit OAuth API (`oauth.reddit.com`). Rounds never posts, votes or comments.
- The client ID and OAuth tokens live in the Keychain, never in source code or app files.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (Swift 6)
- A Reddit account, to register a free "installed app"

## 1. Register a Reddit app

1. Sign in at <https://www.reddit.com/prefs/apps>.
2. Click **create another app…** at the bottom of the page.
3. Fill in:
   - **name:** `Rounds`
   - **type:** `installed app`
   - **redirect uri:** `rounds://oauth` (only used if you connect your account to import saved threads)
4. Click **create app**. The **client ID** is the short string shown under the app name ("installed app").

Installed apps have no secret. Rounds authenticates with the
`https://oauth.reddit.com/grants/installed_client` grant, using a random per-install `device_id`. The app-only token is cached in the Keychain until it expires.

If you connect your account (Settings → Reddit Account → Connect…), Rounds runs the OAuth code flow with
`duration=permanent` and the scopes `read history identity`, then imports the threads you've saved on Reddit (`/user/{you}/saved`).

## 2. Build and run

From the repository root:

```bash
xcodebuild -project Rounds.xcodeproj -scheme Rounds -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build build \
  && open build/Build/Products/Debug/Rounds.app
```

or `scripts/build-and-run.sh`. You can also open `Rounds.xcodeproj` in Xcode and press ⌘R.

Xcode resolves GRDB through Swift Package Manager on the first build, so the first build needs network access. The app is signed to run locally (ad hoc, `CODE_SIGN_IDENTITY = -`), so no developer team is needed. To distribute it, set your team in the target's Signing & Capabilities.

If the checked-in project ever gives you trouble, regenerate it with XcodeGen: `brew install xcodegen && xcodegen generate`. The spec is in `project.yml`.

### Keep it up to date automatically

```bash
scripts/install-auto-update.sh
```

This installs a background job (a launch agent) that checks GitHub at login and every 5 minutes. When `main` has new commits, it pulls them into this clone, builds a Release copy, and installs it as `/Applications/Rounds.app`. If Rounds is open, it quits it and reopens the new version, then posts a notification. Use the copy in `/Applications` from then on.

- It needs Xcode, and git has to reach GitHub without prompting (HTTPS with the macOS keychain, or an SSH key in your agent).
- Keep the clone outside Desktop, Documents and Downloads, because macOS blocks background jobs there.
- Your work is left alone: if the clone is on another branch or has uncommitted changes, the job skips that run.
- A commit that fails to build leaves the installed app as it was and posts a notification. The next commit is tried as normal.
- The log is `~/Library/Logs/Rounds-auto-update.log`. Turn it off with `scripts/uninstall-auto-update.sh`.

## 3. First launch

Onboarding walks you through:

1. Creating the installed app at reddit.com/prefs/apps
2. Pasting the client ID. Rounds verifies it by requesting a token.
3. Confirming the default subreddits: r/mdphd, r/medicalschool, r/medicine, r/medschool, r/mcat
4. Running the first sync

The first sync takes a few minutes. Reddit allows roughly 100 requests a minute, and Rounds fetches comments for each thread it keeps.

## Tests

```bash
swift test --package-path RoundsCore          # SwiftPM, works on macOS and Linux
xcodebuild -project Rounds.xcodeproj -scheme Rounds -destination 'platform=macOS' test
```

The suite (50 tests) covers:

| Area | File |
|---|---|
| Subreddit name parsing and validation | `SubredditNameTests.swift` |
| Relevance scoring and "why it surfaced" strings | `RelevanceScorerTests.swift` |
| Link extraction, normalization, dedupe; thread classification | `LinkExtractorTests.swift` |
| FTS5 search, filters, counts, index rebuild | `SearchTests.swift` |
| API client against canned JSON (decoding, 429 back-off, `/about` errors, token grant) | `RedditClientTests.swift` |
| Sync engine end to end (incremental upsert, re-score, prune, saved import) | `SyncEngineTests.swift` |

All network access goes through the `HTTPTransport` protocol. The tests swap in `MockTransport`, which serves fixtures from `Fixtures.swift`.

## How it works

### Layout

```
Rounds.xcodeproj         App target + RoundsTests target, shared "Rounds" scheme
App/                     SwiftUI app (AppModel, views, Settings, onboarding, menu bar, Spotlight, notifications)
RoundsCore/              Swift package with all logic, built and tested independently
  Sources/RoundsCore/
    Models.swift           Subreddit, RedditThread, Comment, Resource (GRDB records)
    AppDatabase.swift      Schema, migrations, FTS5 index, queries, maintenance
    SyncEngine.swift       Actor-based incremental syncer
    RedditClient.swift     oauth.reddit.com client behind the RedditAPI protocol
    RedditAuth.swift       installed_client grant, code flow, token refresh
    RateLimiter.swift      Request queue driven by X-Ratelimit-* headers
    HTTPTransport.swift    Network seam (URLSession in the app, mocks in tests)
    SecretStore.swift      Keychain storage
    RelevanceScorer.swift  0–100 score and the "why it surfaced" line
    LinkExtractor.swift    Link extraction and normalization
    ThreadClassifier.swift Discussion / Question / Resource
    SubredditName.swift    Parsing r/name, /r/name and reddit.com URLs
  Tests/RoundsCoreTests/
Config/Rounds.entitlements  App Sandbox + outgoing network
```

### Sync

`SyncEngine` is an actor. Calls made while a pass is running join that pass's queue, so adding a subreddit during a sync just queues it. Each subreddit pass:

1. Fetches `/r/{sub}/top?t={window}`, paginated up to the keep limit, plus `/r/{sub}/hot` (stickied posts skipped).
2. Upserts threads by id. Comments (`/comments/{id}?sort=top&limit=N`) are fetched only for new threads, threads whose comment count changed, and, on **Sync now**, threads whose comments are more than a day old. Threads below the upvote filter or hidden as image/meme posts don't spend comment requests.
3. Re-scores every thread in the subreddit, so a change in score or comment count is reflected right away.
4. Prunes threads beyond the per-subreddit limit by relevance. Saved threads are never pruned, even after they drop out of the top list.

The scheduler checks once a minute and syncs subreddits that are older than the chosen interval. **Sync now** runs a full pass over every enabled subreddit immediately.

### Rate limiting

Every request goes through `RateLimiter`. It reads `X-Ratelimit-Remaining` and `X-Ratelimit-Reset`, spaces requests across what's left of the window, and waits for the reset when the budget runs out. A 429 (or a 5xx) pauses the whole queue, honoring `Retry-After` and otherwise backing off exponentially (2s, 4s, 8s, 16s) before giving up. A 401 refreshes the token once.

Requests send a descriptive User-Agent, `macos:com.naren.rounds:v1.0 (by /u/<username>)`. Set your username in onboarding or Settings → Reddit Account.

### Relevance score (0–100)

A weighted mix of four normalized signals. The weights are adjustable in Settings → Relevance.

| Signal | Computation |
|---|---|
| Upvotes | `log(1+score) / log(1+max score in the subreddit)` |
| Discussion | `0.7 × log-normalized comment count + 0.3 × min(reply depth, 5)/5` |
| Resources | `min(unique external links in post + comments, 4) / 4` |
| Keywords | `1 − 0.4^matches`, using global plus per-subreddit keywords matched as whole words (case-insensitive) in the title, body and comments |

The "why it surfaced" line names the strongest signal ("Top discussion in r/mdphd this month"), adds a strong runner-up ("214 comments"), and lists matched keywords ("matches: MSTP, interviews").

Filters (hide image/meme posts, hide threads under N upvotes) apply when the library is displayed, so toggling them is instant. Saved threads are never hidden.

### Classification

- **Resource:** the post links to a document host (Google Docs/Drive/Sheets, Dropbox, Notion, AnkiWeb, GitHub…) or a file (`.pdf`, `.xlsx`, `.csv`, `.apkg`…), links to two or more external pages, or its title mentions decks, spreadsheets, Anki, templates or resources and isn't a question.
- **Question:** the title ends in `?` or starts with an interrogative ("How", "Is", "Should", "Anyone"…).
- **Discussion:** everything else.

### Links

Rounds pulls every Markdown and bare link out of posts and comments, decodes HTML entities and Reddit's escapes, and unwraps redirectors (google.com/url, out.reddit.com). It then normalizes each link: lower-case host, no `www.`, no fragment or default port, no tracking parameters (`utm_*`, `fbclid`, `gclid`, `si`, `ref`…), and no trailing slash. Links are deduplicated per thread and stored as Resources with their source comment. Links back to Reddit itself are skipped.

### Search

A single FTS5 table (`porter unicode61` tokenizer) has one row per thread, covering the title, body, all stored comments, and resource titles, domains and URLs. As you type, each term becomes a prefix query (`"mstp"* "interv"*`). Results are ranked by BM25, with the title weighted highest, then blended with relevance. Settings → Search & Storage shows the index size and lets you rebuild it, clear all data, or mirror threads into Spotlight with CoreSpotlight.

## Data locations

- Database: `~/Library/Containers/com.naren.rounds/Data/Library/Application Support/Rounds/rounds.sqlite`
- Settings: the app's sandboxed `UserDefaults`
- Secrets: login Keychain, service `com.naren.rounds`

## Web version

`web/` is a static port of Rounds for browsers and phones (it is what the bollineni-create launcher hosts at `/rounds/`). It has no build step: `index.html`, `css/app.css` and plain scripts in `js/` (`core.js` for parsing, classification, scoring and search; `reddit.js`, `db.js`, `sync.js`, `app.js`).

- Same model as the Mac app: subreddits with a time window, kinds and keywords; relevance scoring with the same weights; resources pulled from posts and comments; Saved threads that are never pruned.
- Data stays in the browser (IndexedDB). Search is a BM25 index over titles, bodies, comments and resources, built in memory.
- Reddit access is read-only. Hosted on the launcher, `/rounds/api/*` is a server route that uses Reddit's OAuth API (installed-client grant) when `REDDIT_CLIENT_ID` is set there. Without it, or when the page runs on its own, Rounds reads Reddit's public JSON straight from the browser and falls back to the server route when Reddit refuses the browser.
- A sync fetches comments for at most 30 threads per subreddit, to stay within Reddit's limits; later syncs fill in the rest.
- Layout: three panes on wide screens; on narrow ones (phones, a folded Surface Duo) the subreddits move into a drawer and the list and thread stack with a back button.

Preview locally with `python3 -m http.server 8650 --directory web`. Run `node -e "require('./web/js/core.js')"` to load the core in Node for quick checks.
