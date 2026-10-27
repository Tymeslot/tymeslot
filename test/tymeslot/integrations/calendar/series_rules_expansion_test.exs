defmodule Tymeslot.Integrations.Calendar.SeriesRulesExpansionTest do
  @moduledoc """
  A series' rule copied onto every cached occurrence describes the series;
  it must never make one occurrence count as many. One place pins it for
  the three providers whose occurrences carry a rule: Google and Outlook
  (stamped from the stored series rule) and CalDAV (its resource's rule, as
  before).

  The grid reads the cache and shows exactly the rows stored. Availability
  reads Google and Outlook live, as single occurrences without a rule, so the
  stamped rows beside them in the cache must change nothing there either.
  CalDAV's live read expands the rule its resource carries, which is how it
  has always answered and is not changed here.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Runtime.EventFetcher
  alias Tymeslot.Security.Encryption

  setup :set_mox_global
  setup :verify_on_exit!

  @rule "FREQ=WEEKLY;BYDAY=MO;COUNT=5"
  @mondays for week <- 0..4, do: DateTime.add(~U[2026-10-05 07:00:00Z], week * 7, :day)

  setup do
    user = insert(:user)
    google = integration(user, "google")
    outlook = integration(user, "outlook")
    caldav = insert(:calendar_integration, user: user, provider: "caldav", is_active: true)

    for {integration, master} <- [{google, "google-master"}, {outlook, "outlook-master"}] do
      cache_series(integration, integration.provider, recurring_event_id: master)
    end

    cache_series(caldav, "caldav", provider_event_id: "/cal/weekly.ics")

    %{user: user, google: google, outlook: outlook, caldav: caldav}
  end

  test "the grid shows one row per occurrence", %{
    google: google,
    outlook: outlook,
    caldav: caldav
  } do
    rows =
      CalendarGrid.list_events_for_range(
        [google.id, outlook.id, caldav.id],
        ~U[2026-10-01 00:00:00Z],
        ~U[2026-11-30 00:00:00Z]
      )

    assert Enum.frequencies_by(rows, & &1.calendar_integration_id) ==
             %{google.id => 5, outlook.id => 5, caldav.id => 5}

    assert Enum.all?(rows, &(&1.recurrence_rule == @rule))
  end

  test "availability counts one busy block per Google and Outlook occurrence", %{user: user} do
    stub(GoogleCalendarAPIMock, :list_primary_events, fn _integration, _from, _to ->
      {:ok, Enum.map(@mondays, &google_instance/1)}
    end)

    stub(OutlookCalendarAPIMock, :list_primary_events, fn _integration, _from, _to ->
      {:ok, Enum.map(@mondays, &outlook_occurrence/1)}
    end)

    stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 207, body: "<multistatus xmlns=\"DAV:\"/>"}}
    end)

    {:ok, events} =
      EventFetcher.get_events_for_range_fresh(user.id, ~D[2026-10-01], ~D[2026-11-30])

    starts = events |> Enum.map(& &1.start_time) |> Enum.sort(DateTime)
    assert starts == Enum.flat_map(@mondays, &[&1, &1])
  end

  defp integration(user, provider) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      is_active: true,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    )
  end

  # Five cached occurrences of a weekly series, each carrying its rule.
  defp cache_series(integration, provider, attrs) do
    for {start, n} <- Enum.with_index(@mondays) do
      insert(
        :provider_calendar_event,
        [
          calendar_integration: integration,
          provider: provider,
          uid: "#{provider}-occurrence-#{n}",
          start_at: start,
          end_at: DateTime.add(start, 1800, :second),
          all_day: false,
          recurrence_rule: @rule
        ] ++ attrs
      )
    end
  end

  defp google_instance(start) do
    %{
      "id" => "google-master_#{Calendar.strftime(start, "%Y%m%dT%H%M%SZ")}",
      "iCalUID" => "google-master@google.com",
      "recurringEventId" => "google-master",
      "originalStartTime" => %{"dateTime" => DateTime.to_iso8601(start)},
      "status" => "confirmed",
      "summary" => "Weekly",
      "start" => %{"dateTime" => DateTime.to_iso8601(start)},
      "end" => %{"dateTime" => start |> DateTime.add(1800, :second) |> DateTime.to_iso8601()}
    }
  end

  defp outlook_occurrence(start) do
    %{
      "id" => "outlook-occurrence-#{DateTime.to_unix(start)}",
      "iCalUId" => "outlook-master-ical",
      "type" => "occurrence",
      "seriesMasterId" => "outlook-master",
      "subject" => "Weekly",
      "isAllDay" => false,
      "start" => %{"dateTime" => naive(start), "timeZone" => "UTC"},
      "end" => %{
        "dateTime" => start |> DateTime.add(1800, :second) |> naive(),
        "timeZone" => "UTC"
      }
    }
  end

  defp naive(datetime), do: datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
end
