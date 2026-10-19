defmodule Tymeslot.CalendarGrid.CalDAVZonedSeriesEditTest do
  @moduledoc """
  A series Tymeslot created on a CalDAV calendar in the organiser's zone,
  then edited from the grid after a DST change. The document the create
  wrote is what the sync caches, so each edit starts from Tymeslot's own
  zoned output: an override names its occurrence by wall clock in the zone,
  a split ends the head with a UTC `UNTIL`, and the new tail is written with
  the zone and its `VTIMEZONE`.

  The `:calendar_module` seam points back at the runtime module, so every
  write travels down to the HTTP client.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Runtime.Operations

  setup :verify_on_exit!

  # Monday 5 October 2026, 09:00 in Berlin (CEST, UTC+2); Berlin goes back
  # to CET on Sunday 25 October.
  @first_start ~U[2026-10-05 07:00:00Z]

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

    stub(Tymeslot.HTTPClientMock, :put, fn url, body, _headers, _opts ->
      send(test_pid, {:put, url, body})
      {:ok, %Req.Response{status: 201, body: "", headers: %{"etag" => ["\"etag-2\""]}}}
    end)

    {series_url, document} = create_series(user, integration)

    %{user: user, integration: integration, series_url: series_url, document: document}
  end

  defp create_series(user, integration) do
    {:ok, _result} =
      EventCreation.run_create_event(%{
        creating: %{
          title: "Weekly sync",
          integration_id: integration.id,
          calendar_id: "/cal/",
          attendees: [],
          recurrence_rule: "FREQ=WEEKLY"
        },
        user_id: user.id,
        start_at: @first_start,
        end_at: DateTime.add(@first_start, 30, :minute),
        timezone: "Europe/Berlin"
      })

    assert_received {:put, url, body}
    assert "DTSTART;TZID=Europe/Berlin:20261005T090000" in LineFolder.unfold_lines(body)
    {url, body}
  end

  # The row the sync caches for the occurrence at `local` (Berlin wall clock)
  # of the series the create wrote.
  defp cached_occurrence(context, local) do
    %{integration: integration, series_url: series_url, document: document} = context
    uid = document |> LineFolder.unfold_lines() |> Enum.find_value(&uid_value/1)
    start_at = local |> DateTime.from_naive!("Europe/Berlin") |> DateTime.shift_zone!("Etc/UTC")
    key = Calendar.strftime(local, "%Y%m%dT%H%M%S")

    insert(:provider_calendar_event,
      calendar_integration: integration,
      uid: "#{uid}_#{key}",
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: URI.parse(series_url).path,
      summary: "Weekly sync",
      start_at: start_at,
      end_at: DateTime.add(start_at, 30, :minute),
      all_day: false,
      timezone: "Europe/Berlin",
      recurrence_rule: "FREQ=WEEKLY",
      provider_metadata: %{"uid" => uid},
      etag: "\"etag-1\"",
      raw_ical: document,
      sync_state: "synced"
    )
  end

  defp uid_value("UID:" <> uid), do: uid
  defp uid_value(_line), do: nil

  defp puts(acc \\ []) do
    receive do
      {:put, url, body} -> puts([{url, LineFolder.unfold_lines(body)} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "an override names its occurrence by wall clock in the series' zone", context do
    occurrence = cached_occurrence(context, ~N[2026-10-12 09:00:00])

    assert {:ok, _updated} =
             CalendarGrid.update_event(context.user.id, occurrence, %{summary: "Moved sync"},
               recurrence_scope: :this_only
             )

    assert [{url, lines}] = puts()
    assert url == context.series_url
    assert "RECURRENCE-ID;TZID=Europe/Berlin:20261012T090000" in lines
    assert "BEGIN:VTIMEZONE" in lines
  end

  test "a split after the DST change ends the head in UTC and zones the tail", context do
    occurrence = cached_occurrence(context, ~N[2026-11-02 09:00:00])

    assert {:ok, _updated} =
             CalendarGrid.update_event(context.user.id, occurrence, %{summary: "New sync"},
               recurrence_scope: :following
             )

    writes = puts()
    assert [{_url, head}] = Enum.filter(writes, &(elem(&1, 0) == context.series_url))
    assert [{_url, tail}] = Enum.reject(writes, &(elem(&1, 0) == context.series_url))

    assert "DTSTART;TZID=Europe/Berlin:20261005T090000" in head
    # A second before the split's occurrence, 09:00 CET (08:00Z) rather than
    # the 07:00Z the first occurrence's CEST offset would give.
    assert "RRULE:FREQ=WEEKLY;UNTIL=20261102T075959Z" in head

    assert "DTSTART;TZID=Europe/Berlin:20261102T090000" in tail
    assert "SUMMARY:New sync" in tail
    assert "BEGIN:VTIMEZONE" in tail
    assert "TZID:Europe/Berlin" in tail
  end
end
