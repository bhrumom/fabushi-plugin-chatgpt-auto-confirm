# Status / changelog

2026-09-05: requirement reconstructed from the user's attachment and current
standalone plugin main. Existing browser host still needs an active execution
lease; installed native approval watcher reports disabled. Added experimental
reply event lifecycle and explicit missing-host rejection, fixed English
“Stop answering” detection. Real hosting, automatic confirmation, publication and
original task dispatch remain incomplete. Existing plugin PR #1 is preserved.

2026-09-05 local-validation follow-up: user explicitly authorized local verification. 44 focused tests passed; initial remote CI also passed (43 tests before added HTTP readiness test). Actual host descriptor is absent. Added bounded callback timeouts and rollback on failed registration persistence. Feature remains blocked at real host adapter integration.
