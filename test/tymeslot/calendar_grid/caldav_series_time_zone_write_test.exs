defmodule Tymeslot.CalendarGrid.CalDAVSeriesTimeZoneWriteTest do
  @moduledoc """
  A repeating event created from the grid on a CalDAV calendar is written in
  the organiser's zone, so every client (and Tymeslot's own sync) keeps it at
  its local time across a DST change. Written in UTC, as it used to be, a
  Berlin 09:00 series created in October showed at 08:00 after the clocks
  went back.

  The `:calendar_module` seam points back at the runtime module, so the
  payload travels the whole way to the HTTP client and the document the
  server receives is read back through the sync's own parser.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.Runtime.Operations

  setup :verify_on_exit!

  setup do
    previous_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous_module,
        do: Application.put_env(:tymeslot, :calendar_module, previous_module),
        else: Application.delete_env(:tymeslot, :calendar_module)
    end)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/cal/"],
        default_booking_calendar_id: "/cal/"
      )

    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, fn _url, body, _headers, _opts ->
      send(test_pid, {:put, body})
      {:ok, %Req.Response{status: 201, body: "", headers: %{}}}
    end)

    %{user: user, integration: integration}
  end

  # Monday 5 October 2026, 09:00 in Berlin (CEST, UTC+2); Berlin goes back
  # to CET on Sunday 25 October.
  @first_start ~U[2026-10-05 07:00:00Z]

  defp create(user, integration, rule, timezone) do
    {:ok, _result} =
      EventCreation.run_create_event(%{
        creating: %{
          title: "Weekly sync",
          integration_id: integration.id,
          calendar_id: "/cal/",
          attendees: [],
          recurrence_rule: rule
        },
        user_id: user.id,
        start_at: @first_start,
        end_at: DateTime.add(@first_start, 30, :minute),
        timezone: timezone
      })

    assert_received {:put, body}
    body
  end

  test "a weekly series keeps 09:00 Berlin time after the clocks go back", %{
    user: user,
    integration: integration
  } do
    body = create(user, integration, "FREQ=WEEKLY;COUNT=6", "Europe/Berlin")
    lines = LineFolder.unfold_lines(body)

    assert "DTSTART;TZID=Europe/Berlin:20261005T090000" in lines
    assert "DTEND;TZID=Europe/Berlin:20261005T093000" in lines
    assert "BEGIN:VTIMEZONE" in lines
    assert "TZID:Europe/Berlin" in lines

    {:ok, raw_events} = ICalParser.parse(body)

    local_starts =
      raw_events
      |> ICalNormaliser.expand_occurrences(~U[2026-10-01 00:00:00Z], ~U[2026-12-01 00:00:00Z])
      |> Enum.map(&(&1.start_time |> DateTime.shift_zone!("Europe/Berlin") |> DateTime.to_time()))

    assert length(local_starts) == 6
    assert Enum.uniq(local_starts) == [~T[09:00:00]]
  end

  test "a one-off event stays in UTC", %{user: user, integration: integration} do
    lines = user |> create(integration, nil, "Europe/Berlin") |> LineFolder.unfold_lines()

    assert "DTSTART:20261005T070000Z" in lines
    refute "BEGIN:VTIMEZONE" in lines
  end
end
