# Sending a continued draft

Send immediately removes the editable draft notice and presents the saved outgoing body in the conversation. The existing Undo action remains available during the hold. The card reports Queued, Sending or Send unconfirmed according to the durable outbox; provider confirmation is required before treating it as sent. Undo restores the editable draft and removes the outgoing projection. A failed send retains the saved draft and existing recovery actions.

The projection reuses the bounded draft working set and prepared text. A confirmed provider message replaces it only when its body is ready, keeping a header-only sync update from producing a duplicate or empty card. The provider message identity is retained with the durable send result. This applies familiar mail behavior and truthful immediate feedback without shortening Undo or delaying the interface for network delivery.

Live-store regression tests cover the Undo hold and restoration, sending, an unconfirmed outcome and provider-body handoff. Composer journeys cover reopening and sending replies and new drafts, restored navigation and removal of the draft notice. These functional checks do not establish physical frame or input latency.
