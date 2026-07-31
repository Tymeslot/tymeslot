# Integration Tests

Integration tests that drive the web layer end to end: OAuth sign-in (Google, GitHub), the Outlook calendar connection, the Slack app journey, the embed pipeline, and layout extension.

**They are hermetic.** No test in this directory reads an environment variable, and every outbound HTTP call goes through `Tymeslot.HTTPClientMock` or a provider mock configured in `config/test.exs`. There are no credentials to set up and no network access is needed.

## Running them

Two of the tags used here are excluded from `mix test` by default (see `test/support/suite_config.ex`), because those modules are `async: false` and would slow down every run. Nothing about them is unreliable, so they are expected to be green:

```bash
mix test --only oauth_integration
mix test --only calendar_integration test/tymeslot_web/integration/outlook_calendar_integration_test.exs
```

Scope the `calendar_integration` run to a path as shown. The tag is also on `test/tymeslot/integrations/calendar/baikal_integration_test.exs`, which is the one genuinely live suite: it drives a Baikal CalDAV server on `localhost:8800`, set up as described in its own `@moduledoc`.

The other modules here carry tags that run by default, so a plain `mix test test/tymeslot_web/integration/` picks them up.

Both excluded tags also run nightly in CI, via `.github/workflows/excluded-suites.yml`, which takes a manual trigger too.

## What the two excluded suites cover

- `oauth_integration`: CSRF state validation, rate limiting on the authorisation endpoints, the error paths for a missing authorisation code or a state the server never issued, the redirect out to the provider, and encrypted storage of the tokens a connection produces.
- `calendar_integration` (Outlook): token refresh and its failure modes, event fetching over Microsoft Graph, scoping integrations to their owner, and transport failures.
