defmodule Tymeslot.Integrations.Calendar.BookingRoundTripTest do
  @moduledoc """
  Pins the invariant the whole external-change detection rests on: a booking
  Tymeslot wrote to a CalDAV calendar, read back through its own sync, must
  come out describing the same instant it went in.

  Nothing held this before. Until `Sync.post_commit_reconciliation/2` learned
  to match a meeting by uid, the comparison never ran for a CalDAV
  integration at all, so a lossy round trip cost nothing; the moment it did
  run, every booking on every CalDAV calendar became a candidate to be
  declared "externally modified" and mailed about. A one-hour drift
  introduced anywhere along the builder → parser → normaliser path would
  therefore reach hosts as a notification about a booking nobody had touched.

  The second test is what makes the first one mean anything: it shows the
  comparison is live for exactly this fixture, so the unflagged result above
  is a real observation rather than a link that silently failed to form.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  describe "a booking written to CalDAV and synced back" do
    test "keeps its exact start time and is not flagged as externally modified" do
      %{integration: integration, meeting: meeting} = booking()

      event = round_trip(meeting, integration)

      # The invariant itself, asserted directly rather than inferred from the
      # absence of a flag: an offset error, a floating-time assumption or a
      # dropped timezone would all land here first.
      assert DateTime.compare(event.start_at, meeting.start_time) == :eq

      assert :ok = Sync.persist_normalised_events(integration, [event])

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == nil
    end

    test "is flagged when the server really did move it" do
      %{integration: integration, meeting: meeting} = booking()

      moved =
        meeting
        |> round_trip(integration)
        |> shift_start(3600)

      assert :ok = Sync.persist_normalised_events(integration, [moved])

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.calendar_sync_status == "externally_modified"
    end
  end

  # A CalDAV booking as the write path leaves it: no provider event id on the
  # meeting, because the server addresses the event by href and only the uid
  # links the two sides.
  defp booking do
    integration = insert(:calendar_integration, provider: "caldav")
    start_time = DateTime.add(DateTime.utc_now(:second), 7, :day)

    meeting =
      insert(:meeting,
        calendar_integration_id: integration.id,
        provider_event_id: nil,
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute)
      )

    %{integration: integration, meeting: meeting}
  end

  # Builder → serialiser → parser → normaliser, the same four steps a booking
  # takes between being written to a CalDAV server and arriving back in the
  # cache. The href and etag are what the multistatus response supplies around
  # the iCal body.
  defp round_trip(meeting, integration) do
    ical =
      meeting
      |> CalendarEventBuilder.build_event_data()
      |> then(&ICalBuilder.build_simple_event(meeting.uid, &1))

    {:ok, [raw]} = ICalParser.parse(ical)

    raw =
      Map.merge(raw, %{
        href: "/cal/primary/#{meeting.uid}.ics",
        etag: "etag-#{System.unique_integer([:positive])}"
      })

    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: "/cal/primary",
      calendar_paths: ["/cal/primary"],
      synced_at: DateTime.utc_now(:microsecond)
    }

    {:ok, [event]} = ICalNormaliser.normalise_events([raw], context, :caldav)

    event
  end

  defp shift_start(%CalendarEvent{} = event, seconds) do
    %{
      event
      | start_at: DateTime.add(event.start_at, seconds, :second),
        end_at: DateTime.add(event.end_at, seconds, :second)
    }
  end
end
