defmodule Tymeslot.Integrations.Calendar.CalDAVCalendarIdBackfillTest do
  @moduledoc """
  Exercises the repair SQL from
  `20260806162257_backfill_caldav_provider_calendar_id` against the data
  shapes an existing installation can hold.

  Every CalDAV sync path used to file a whole batch under the integration's
  first calendar path, so the rows this repairs are misfiled by construction:
  the only record of an event's true origin is its href. The migration reads
  that href back, which makes "what happens to an href the paths do not
  explain?" the question worth answering, in several forms.

  The SQL is read out of the migration file rather than copied here. A copy
  passes forever once the migration is edited, and this test exists precisely
  to say whether *that file* is correct.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :database

  import Tymeslot.Factory

  alias Tymeslot.Repo

  @migration "priv/repo/migrations/20260806162257_backfill_caldav_provider_calendar_id.exs"

  @main "/luka/main-calendar/"
  @block "/luka/block-calendar/"

  # The heredoc passed to `execute/1`, taken from the migration itself.
  defp backfill_sql do
    source = File.read!(Path.join(File.cwd!(), @migration))

    case Regex.run(~r/execute\("""\n(.*?)\n\s*"""\)/s, source) do
      [_whole_match, sql] -> sql
      nil -> flunk("could not extract the backfill SQL from #{@migration}")
    end
  end

  defp run_backfill! do
    Repo.query!(backfill_sql())
  end

  defp integration(paths, opts \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge([provider: "radicale", calendar_paths: paths], opts)
    )
  end

  # Reproduces the pre-fix cache: the href records the real collection while
  # `provider_calendar_id` names whichever calendar happened to be listed first.
  defp misfiled_event(integration, href, filed_under) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "radicale",
      provider_event_id: href,
      provider_calendar_id: filed_under
    )
  end

  defp filed_under(event_id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT provider_calendar_id FROM provider_calendar_events WHERE id = $1", [
        event_id
      ])

    value
  end

  describe "repairing misfiled CalDAV rows" do
    test "moves each event to the collection its href is rooted at" do
      integ = integration([@main, @block])
      stays = misfiled_event(integ, @main <> "a.ics", @main)
      moves = misfiled_event(integ, @block <> "b.ics", @main)

      run_backfill!()

      assert filed_under(stays.id) == @main
      assert filed_under(moves.id) == @block
    end

    test "prefers the deepest matching collection when paths nest" do
      nested = @main <> "shared/"
      integ = integration([@main, nested])
      event = misfiled_event(integ, nested <> "c.ics", @main)

      run_backfill!()

      assert filed_under(event.id) == nested
    end

    test "is idempotent" do
      integ = integration([@main, @block])
      event = misfiled_event(integ, @block <> "b.ics", @main)

      run_backfill!()
      run_backfill!()

      assert filed_under(event.id) == @block
    end
  end

  describe "rows it must not touch" do
    test "leaves an href matching none of the integration's paths alone" do
      # A server whose hrefs are not rooted at the advertised collection path.
      # Guessing would scatter its events across calendars that never held
      # them; leaving them filed as before keeps the old behaviour.
      integ = integration([@main, @block])
      event = misfiled_event(integ, "/somewhere/else/d.ics", @main)

      run_backfill!()

      assert filed_under(event.id) == @main
    end

    test "leaves non-CalDAV rows alone even when a path would match" do
      # Google and Outlook ids are opaque strings, not hrefs, and those
      # providers already record the originating calendar correctly. Only an
      # href may be read as a path, so an opaque id that happens to start with
      # one has to keep the calendar its own provider reported.
      integ = integration(["evt"], provider: "google")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integ,
          provider: "google",
          provider_event_id: "evt-12345",
          provider_calendar_id: "primary"
        )

      run_backfill!()

      assert filed_under(event.id) == "primary"
    end

    test "leaves an href that merely contains a path somewhere in the middle" do
      # A collection path identifies an event only when the href is rooted at
      # it. An href that embeds the string further along belongs to a
      # different collection, and matching it would file the event under a
      # calendar that never held it.
      integ = integration([@main])
      event = misfiled_event(integ, "/archive" <> @main <> "a.ics", @block)

      run_backfill!()

      assert filed_under(event.id) == @block
    end

    test "leaves rows whose calendar is already correct alone" do
      integ = integration([@main, @block])
      event = misfiled_event(integ, @block <> "b.ics", @block)

      run_backfill!()

      assert filed_under(event.id) == @block
    end

    test "leaves an integration listing no paths alone" do
      integ = integration([])
      event = misfiled_event(integ, @block <> "b.ics", @main)

      run_backfill!()

      assert filed_under(event.id) == @main
    end

    test "survives an integration whose calendar_paths is NULL" do
      # The column defaults to an empty array, but a row predating the default
      # can hold NULL, and `unnest(NULL)` must not take the migration down.
      integ = integration([@main])
      event = misfiled_event(integ, @main <> "a.ics", @main)

      Repo.query!("UPDATE calendar_integrations SET calendar_paths = NULL WHERE id = $1", [
        integ.id
      ])

      run_backfill!()

      assert filed_under(event.id) == @main
    end
  end

  describe "keeping accounts apart" do
    test "does not file an event under an identical path belonging to another account" do
      # Two Radicale accounts on different servers can advertise the same
      # collection path. The href alone cannot tell them apart, so the repair
      # has to stay inside the event's own integration.
      mine = integration([@main])
      theirs = integration([@main, @block])

      event = misfiled_event(mine, @block <> "b.ics", @main)
      _decoy = misfiled_event(theirs, @block <> "b.ics", @main)

      run_backfill!()

      # `@block` is not one of `mine`'s paths, so this row has no match and
      # must be left as it was rather than borrowing the other account's.
      assert filed_under(event.id) == @main
    end
  end
end
