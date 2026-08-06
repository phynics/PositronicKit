# JRN-5 — Inspection pipeline's response-capture seam is acknowledged-unfinished

**Status:** Done
**Severity:** 🟡 Low (decide: finish or remove the placeholder)
**Repos:** PositronicKit
**Source:** Journaling audit 2026-07-02

## Problem

`InspectionDTOs.swift:112-117` states that `TurnInspection` "does not currently carry response
metadata; this DTO exists so `TurnInspectionModel.responseData` has a stable shape ready for a
future turn where response capture is wired up." The inspection/journal pipeline thus ships a
placeholder DTO implying planned work that is not scheduled anywhere.

## Suggested direction

Either schedule and wire response capture into `TurnInspection` (so the Journal/Response
inspection surfaces engine-side response metadata), or remove/reword the placeholder so the DTO
surface doesn't advertise unbuilt functionality.

## Resolution (2026-07-04)

Investigation found that response capture is already fully wired up — the placeholder framing in
the `ResponseDTO` doc comment was stale:

- `ChatEventReducer.responseDTO` produces the initial `ResponseDTO` from accumulated
  `ChatTurnState` (reconstructed text, thinking, model, finish reason, tokens, tool traces,
  structured output fields).
- `ChatViewModel.enrichedResponseDTO(from:)` enriches it with typed-reply decoding results before
  persisting.
- `SwiftDataTurnInspector` persists/loads it via `TurnInspectionModel.responseData`
  (`updateResponse`, `updateLatestResponse`, `decodedResponse`).
- `InspectionPresentation.response` surfaces it to `ResponseInspectorView`.

Reworded the doc comment to describe the actual pipeline instead of advertising "a future turn
where response capture is wired up." No code changes — the response-capture seam was already
complete; only the doc was stale.

The DTO lives in `Yakamoz/Sources/YakamozCore/Inspection/InspectionDTOs.swift` (not in
PositronicKit itself — the ticket's "Repos: PositronicKit" was from the journaling audit's
perspective; the inspection DTOs are Yakamoz-owned).

289 Yakamoz tests green.
