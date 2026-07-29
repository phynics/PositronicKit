# PKRR-028 API Disposition

Resolution: Done as an audit-only ticket. No public API was removed. Existing
deprecations are retained, and one stale documentation reference was corrected.

## Verification

The audit was run against the `pkrr-028-worktree` checkout at the current
revision and against the local `Monad`, `Shuttle`, `Yakamoz`, and `LandGo`
checkouts. Searches covered Swift source in both `Sources` and `Tests`.

Commands run:

- `swift package dump-symbol-graph` (exit nonzero after building; SwiftPM
  reported the existing duplicate `PKFastEmbed` dependency warning and the
  final link failed on missing `pkfastembed` symbols)
- `swift package describe --type json`
- `swift build` (the package compiled through module emission, but final
  linking failed because the native `pkfastembed` library and `stdc++` were not
  available on this host; the command also reported the existing SwiftUICore
  client restriction while linking the example product)
- `xcrun --find swift-symbolgraph-extract`
- `xcrun swift-symbolgraph-extract` for each current library product, using
  `-minimum-access-level public`, the package build Modules directory, the
  macOS 15 SDK, and target `arm64-apple-macosx15.0`

Direct symbol-graph extraction succeeded for these products: `PositronicKit`,
`PKObservable`, `PKPrompt`, `PKShared`, `PKUtilities`, `PKOpenAIProvider`,
`PKOpenRouterProvider`, `PKOllamaProvider`, `PKAnthropicProvider`,
`PKFoundationModelsProvider`, and `PKTestSupport`. `PKLocalEmbeddings` could
not be extracted because loading it requires the missing `CPKFastEmbed`
module. The extractor itself was available at:

`/Applications/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-symbolgraph-extract`

The generated graphs contain the candidate symbols, including
`TimelineManager.registerTask(_:sendID:for:)`, both deprecated event cases,
their factory methods, and the public `llmService` compatibility members.

## Dispositions

### `TimelineManager.registerTask(_:sendID:for:)`

Disposition: **keep/document**.

- Production caller: `Sources/PositronicKit/Services/Chat/ChatEngine.swift:272`
  registers the active send task with its `sendID`.
- Public implementation: `Sources/PositronicKit/Services/Timeline/TimelineManager.swift:426`.
- Package tests exercise registration and stale-send cancellation in
  `Tests/PositronicKitTests/TimelineCancellationTests.swift` and
  `TimelineManagerTests.swift`.
- Monad has a production `ChatAPIController` registration call at
  `Monad/Sources/MonadServer/Controllers/ChatAPIController.swift:171`, but it
  uses the older `registerTask(_:for:)` shape and therefore identifies a
  downstream migration gap, not an orphan. It must not be removed or narrowed
  without a Monad pin/migration update.
- Shuttle, Yakamoz, and LandGo have no references.

The send-scoped registration is part of the cancellation and eviction
contract established by PKRR-002. No code change is warranted here.

### `ChatEvent.MetaEvent.generationCompleted`

Disposition: **deprecate with removal release**.

- No producer exists in PositronicKit production code. The canonical producer
  is `ChatEvent.CompletionEvent.generationCompleted`, emitted by
  `MessagePersistenceStage`.
- The case is already deprecated in `Sources/PKShared/SharedTypes/ChatEvent.swift:159`
  with an explicit Codable-compatibility rationale.
- PositronicKit tests assert that it is not emitted; the examples retain an
  exhaustive compatibility branch.
- Yakamoz production code still accepts it in
  `Yakamoz/Sources/YakamozCore/Chat/ChatEventReducer.swift:412`.
- Monad, Shuttle, and LandGo have no direct use of this meta case.

Retain through the next compatible release line so persisted/transported event
payloads can still decode. Remove only in a planned major release after
Yakamoz and any external Codable consumers have migrated.

### `ChatEvent.CompletionEvent.streamCompleted`

Disposition: **deprecate with removal release**.

- PositronicKit's runtime does not emit this case; it emits path-specific
  terminal cases or throws.
- The case is already deprecated in
  `Sources/PKShared/SharedTypes/ChatEvent.swift:206` and retained for Codable
  round-tripping.
- This is not producer-free across the workspace: Monad's production
  `ChatAPIController` emits `ChatEvent.streamCompleted()` at line 162, and
  Monad's SSE reader and CLI consume it. Yakamoz's reducer also handles it;
  Yakamoz tests use the factory to model host/test streams.
- Shuttle and LandGo have no references.

The existing deprecation is intentional, but the downstream host contract
means removal requires a coordinated Monad/Yakamoz migration and a major
release. No removal is justified by this audit.

### Deprecated `llmService` compatibility APIs

Disposition: **deprecate with removal release**.

The public symbol graph contains the deprecated facade/property and grouped
configuration compatibility members:

- `PositronicKit.llmService`
- `PositronicKit.init(llmService:)`
- `PositronicKit.reconfigured(llmService:generationParameters:)`
- `PositronicKit.ProviderConfiguration.llmService`
- Both `ProviderConfiguration.init(llmService:embeddingService:)` overloads

All are already annotated with `@available(*, deprecated, renamed: ...)`.
Package tests and `PKTestSupport` still use the old construction label in test
fixtures, while production code uses `languageModel`. No direct use of these
compatibility APIs was found in Monad, Shuttle, Yakamoz, or LandGo; similarly
named local variables and injected service parameters are not calls to these
APIs. `TimelineArchiver`'s internal `llmService` parameter is a separate
utility-client dependency and is not part of this compatibility surface.

Keep the shims through the next release line for external consumers, then
remove them in a major release after the package test fixtures and downstream
source have migrated. The grouped-configuration documentation now names the
canonical `languageModel` initializer instead of directing users to the
deprecated label.

## Changelog decision

`CHANGELOG.md` was not changed. This audit removes nothing and adds no new
deprecation annotation; the candidates already carried their justified
deprecation markers. The only source edit corrects stale documentation.
