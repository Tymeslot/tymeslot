defmodule Tymeslot.Repo.Migrations.AddRoleToProviderCalendarEvents do
  use Ecto.Migration

  @moduledoc """
  Splits the event cache into rows that block time and rows that are only ever
  displayed.

  Until now every cached row did both jobs: it blocked availability and it
  appeared on the dashboard grid. Exchange breaks that pairing. Its busy time
  has to be read from `GetUserAvailability`, which expands recurring series
  server-side but returns no event identity at all (no id, no subject, no
  change key), while its per-event detail has to be read from the item path,
  whose recurring masters describe only their own first occurrence and would
  therefore be wrong from day two onwards if they blocked time.

  So the two questions come apart, and `role` is what tells the two reads which
  rows are theirs:

    * `both`         — blocks availability, shows in the grid. Every other
                       provider, and the default.
    * `display_only` — shows in the grid, blocks nothing.
    * `busy_only`    — blocks availability, never shown.

  Three values rather than a pair of booleans: the fourth combination would be
  a row that neither read can ever return, and there is no reason to be able to
  write one.

  Existing rows all default to `both`, which is correct rather than merely
  convenient — everything written before this migration came from an item path
  that both blocked and displayed.

  ## How `role` composes with `transparency` and `status`

  It does not replace them, and neither one overrides the other. They answer
  different questions at different levels:

    * `role` is a **query-level** filter: which rows are eligible for a given
      read at all. The availability read takes everything except `display_only`;
      the grid takes everything except `busy_only`.
    * `transparency` and `status` are **row-level**: given an eligible row, does
      it actually block. `CalendarEvent.blocking?/1`, the one function the whole
      availability calculation routes through, dispatches on those two and never
      looks at `role`.

  The consequence for whoever writes the Exchange reads: **a busy interval
  written with `role = 'busy_only'` but without `transparency: 'opaque'` will
  not block time**, because `blocking?/1` never consults `role`. Setting the
  discriminator is not enough; the row still has to declare itself opaque and
  not cancelled or declined. That is precisely the failure this column exists to
  prevent, so it belongs in the provider's tests as an assertion rather than an
  assumption.

  `transparency` was not simply reused for the job because it means something
  else. It is the *event's own* declaration, carried through from the calendar
  protocol (`TRANSP` in iCalendar, the free/busy status in the Microsoft ones);
  `role` is *our* policy about which read path owns the row. An Exchange row
  from the item path can legitimately be `opaque` — the meeting really is busy
  time, the organiser said so — and must still not block, because that path
  cannot be trusted to have expanded the series. One column cannot carry both
  meanings without losing one of them.

  ## Rolling back

  This migration and `20260819170102_add_exchange_to_calendar_provider_constraint`
  are a pair, and only the later half of it is safe to roll back on its own.
  Dropping `role` while the provider constraint still admits `exchange` leaves a
  database that is silently wrong rather than merely older: the Exchange rows
  survive, their `display_only` rows start blocking availability and their
  `busy_only` rows start appearing in the grid, with nothing to signal either.
  Roll back both (`--step 2`) or neither.

  ## Indexes

  None is created here, deliberately. Both reads want almost every row —
  everything *except* one value of three — so an index on `role` cannot serve
  either of them: Postgres will select the window through the existing
  `(calendar_integration_id, start_at)` and `(calendar_integration_id,
  start_date)` indexes and filter `role` on the heap. Meanwhile this table is
  upserted on every calendar sync for every user of every provider, so such an
  index would be pure write cost. If the real queries turn out to want one, it
  should be chosen with `EXPLAIN` against those queries by whoever writes them,
  not guessed in advance here.

  ## Why one meeting can hold two rows

  An Exchange meeting read both ways is cached twice, once per read, and that
  only works because the two reads produce uids in disjoint namespaces:
  `GetUserAvailability` returns no identity at all, so its rows carry a
  synthesised uid, while the item path carries the real one. Nothing in the
  schema records that assumption. If some future path ever produced the same uid
  from both reads, the unique index `(calendar_integration_id, uid)` would
  silently collapse the two into whichever `role` was written first, and because
  `role` is deliberately outside `ProviderCalendarEventQueries.replace_fields/0`
  the second read could not correct it. The namespaces have to stay disjoint by
  construction.
  """

  def change do
    alter table(:provider_calendar_events) do
      # The default is what puts every pre-existing row on the item side, so it
      # is load-bearing, not a convenience. Postgres 11+ records a non-volatile
      # default in the catalogue instead of rewriting the table, so the ACCESS
      # EXCLUSIVE lock is held for a catalogue update rather than a full scan.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add(:role, :string, null: false, default: "both")
    end

    # The column is added in this same migration and every row therefore holds
    # the default, so the validation scan cannot fail. Migrations run offline:
    # `start.sh` executes them in a one-shot VM and only starts Phoenix once
    # they finish, so the lock blocks no traffic.
    # excellent_migrations:safety-assured-for-next-line check_constraint_added
    create(
      constraint(:provider_calendar_events, :provider_calendar_events_role_check,
        check: "role IN ('both', 'display_only', 'busy_only')"
      )
    )
  end
end
