# Provider capability matrix

The common request surface remains provider-neutral. When an adapter cannot preserve an option exactly, PositronicKit emits one structured warning for that turn. Warning metadata contains only provider/model identity, option category, reason, timeline ID, and turn index.

| Provider | Tools | Tool choice | Response format | Generation variance |
| --- | --- | --- | --- | --- |
| OpenAI | Native | Native | Native JSON/text/schema | None known |
| OpenRouter | Native | Native | Native JSON/text/schema | Model-dependent; adapter behavior follows the routed model |
| Ollama | Native | Adapter/model-dependent | JSON/schema support is model-dependent | `seed` is not sent by the shared adapter |
| Anthropic | Native `input_schema` | Adapter-coerced | Synthetic-tool path for structured output | `seed` is not sent by the shared adapter |
| Foundation Models | Framework-native | Framework-native | Framework-native | Device/model availability is host-dependent |

Warnings never include prompts, tool arguments, or response content.
