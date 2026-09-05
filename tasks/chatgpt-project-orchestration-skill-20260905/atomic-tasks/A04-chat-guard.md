# A04 — Chat Web mode and model guard

- **Status:** `planned`
- **Goal:** Prevent sends unless the real Chat surface, Chat mode, GPT-5.6 Sol, and Extra High are verified.
- **Owns:** pre-send surface/model validation
- **Depends on:** A00
- **Produces:** guard and negative tests
- **Acceptance:** Work mode, wrong model, wrong reasoning level, missing composer, or unknown page state fail closed.
- **Blocked by:** Browser accessibility contract
