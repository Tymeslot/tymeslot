defmodule Tymeslot.Integrations.Calendar.CalDAV.CalendarAttributionTest do
  @moduledoc """
  Which calendar a cached CalDAV event is filed under.

  A CalDAV account is several collections behind one integration, but the sync
  builds one normalisation context for a whole batch. Filing every event under
  the context's calendar puts an account's entire history under whichever
  calendar happens to be listed first, which is invisible until something keys
  on the column: the per-calendar colour and visibility controls did, and did
  nothing for every calendar but the first.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor

  @main "/luka/main-calendar/"
  @block "/luka/block-calendar/"

  defp context(paths) do
    %{
      calendar_integration_id: 1,
      provider_calendar_id: List.first(paths),
      calendar_paths: paths,
      synced_at: DateTime.utc_now(:microsecond)
    }
  end

  defp raw_event(href, uid) do
    %{
      uid: uid,
      href: href,
      summary: "Event #{uid}",
      dtstart: ~U[2030-03-15 10:00:00Z],
      dtend: ~U[2030-03-15 11:00:00Z]
    }
  end

  defp calendar_ids(raw_events, paths) do
    {:ok, events} = EventProcessor.normalise_events(raw_events, context(paths))
    Enum.map(events, & &1.provider_calendar_id)
  end

  describe "normalise_events/2" do
    test "files each event under the collection its href is rooted at" do
      # The whole bug in one assertion: both events arrive in one batch, under
      # one context, and must still land on different calendars.
      raw = [raw_event(@main <> "a.ics", "a"), raw_event(@block <> "b.ics", "b")]

      assert calendar_ids(raw, [@main, @block]) == [@main, @block]
    end

    test "files an event under a later path even when it is not the first" do
      raw = [raw_event(@block <> "b.ics", "b")]

      refute calendar_ids(raw, [@main, @block]) == [@main]
    end

    test "prefers the deepest matching collection when paths nest" do
      nested = @main <> "shared/"
      raw = [raw_event(nested <> "c.ics", "c")]

      assert calendar_ids(raw, [@main, nested]) == [nested]
    end

    test "falls back to the context for an href matching no known path" do
      # A server whose hrefs are shaped unexpectedly must keep syncing rather
      # than have a calendar invented for it.
      raw = [raw_event("/somewhere/else/d.ics", "d")]

      assert calendar_ids(raw, [@main, @block]) == [@main]
    end

    test "falls back to the context when the event carries no href" do
      raw = [Map.delete(raw_event(@main <> "e.ics", "e"), :href)]

      assert calendar_ids(raw, [@main, @block]) == [@main]
    end

    test "falls back to the context when the integration lists no paths" do
      raw = [raw_event(@main <> "f.ics", "f")]

      assert calendar_ids(raw, []) == [nil]
    end
  end
end
