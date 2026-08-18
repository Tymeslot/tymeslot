# Seeded CalDAV test server

A Radicale container preloaded with the account and calendar the live CalDAV
integration test expects, so the test can be run from a fresh clone without
reverse-engineering a server setup.

```
docker compose -f docker/caldav-test/compose.yml up -d
```

| | |
|---|---|
| base URL | `http://localhost:8800` |
| username | `testuser` |
| password | `testpass123` |
| calendar path | `/testuser/default/` |
| calendar name | `Test Calendar` |

These are the defaults in
`test/tymeslot/integrations/calendar/caldav_live_integration_test.exs`, so with
the container up the module needs no environment variables:

```
mix test --only calendar_integration \
  test/tymeslot/integrations/calendar/caldav_live_integration_test.exs
```

With no server running the module skips rather than fails.

## What is checked in, and why

* `config` — Radicale's configuration. `[auth] type = htpasswd`, deliberately:
  under the default `type = none` every password is accepted, so the test
  asserting a wrong password is rejected would pass without exercising
  authentication at all.
* `users` — an htpasswd line for `testuser` / `testpass123` (bcrypt). It is a
  throwaway credential for a local container and is not a secret.
* `seed/collection-root/testuser/default/.Radicale.props` — the calendar
  collection. Radicale stores a collection as a directory plus this properties
  file, which is what names it "Test Calendar"; without it the account exists
  with no calendar and discovery finds nothing.

The container writes events into `seed/` as `.ics` files while the tests run.
They are ignored by git (see `.gitignore` in this directory). To reset the
server completely:

```
docker compose -f docker/caldav-test/compose.yml down
git clean -fdx docker/caldav-test/seed
docker compose -f docker/caldav-test/compose.yml up -d
```

## Not wired into CI

`.github/workflows/excluded-suites.yml` still runs only the hermetic half of
`:calendar_integration`. This recipe makes a seeded server reproducible
locally, but it has not been proven as a CI service container — a nightly job
that fails for an environmental reason is worse than an honest exclusion.
