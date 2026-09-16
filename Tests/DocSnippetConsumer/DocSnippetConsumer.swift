// This target exists only for the docs-snippet type-check gate.
//
// `Scripts/compile-doc-snippets.sh` extracts every ```swift block under `docs/`,
// writes a generated, bindable wrapper into `Generated/`, and builds this target
// with `swift build --target DocSnippetConsumer`. Nothing here is part of a
// shipped product; the `Generated/` directory is git-ignored.
enum DocSnippetConsumer {}
