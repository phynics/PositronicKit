// PKPrompt is the optional prompt-authoring product. Its prompt model, section metadata,
// token budgeting, and compression live in the package-internal `PKUtilities` target so the
// runtime can share them without importing this product. Re-exporting keeps the authoring
// surface reachable through `import PKPrompt`.
@_exported import PKUtilities
