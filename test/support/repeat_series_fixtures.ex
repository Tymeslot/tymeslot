defmodule TymeslotWeb.RepeatSeriesFixtures do
  @moduledoc """
  A weekly series that began on Wednesday 30 September 2026, its 14 October
  occurrence, and the steps of changing its repeat pattern in the grid's
  editor, for the repeat editor's LiveView tests on Google, Outlook and
  CalDAV. Only the HTTP client is mocked: `serve/1` answers every Google or
  Outlook request with the series' master and `expect_puts/1` takes CalDAV's
  writes, each sent back to the test.
  """

  import ExUnit.Assertions
  import Mox
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Security.Encryption

  @endpoint TymeslotWeb.Endpoint
  @timeout 5_000
  @editor_form "#recurrence-editor-form-update_event_recurrence"
  @series_start ~U[2026-09-30 09:00:00Z]
  @opened ~U[2026-10-14 09:00:00Z]

  @doc "A Google or Outlook calendar of `user` with a token that has not expired."
  @spec oauth_integration(map(), String.t(), String.t()) :: map()
  def oauth_integration(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(Clock.utc_now(), 3600),
      oauth_scope: scope
    )
  end

  @doc "The series' rule and first start, as the sync reads them from the master."
  @spec cache_series_rule(map(), String.t()) :: {:ok, map()}
  def cache_series_rule(integration, master_id) do
    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, master_id, %{
        rule: "FREQ=WEEKLY;BYDAY=WE",
        master_start: @series_start,
        fetched_at: DateTime.utc_now()
      })
  end

  @doc "The 14 October occurrence of the weekly series, cached on `integration`, with `attrs`."
  @spec occurrence(map(), map()) :: map()
  def occurrence(integration, attrs) do
    insert(
      :provider_calendar_event,
      Map.merge(
        %{
          calendar_integration: integration,
          provider_calendar_id: "team-calendar",
          summary: "Weekly sync",
          start_at: @opened,
          end_at: DateTime.add(@opened, 1, :hour),
          all_day: false,
          timezone: "Etc/UTC",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=WE",
          sync_state: "synced"
        },
        attrs
      )
    )
  end

  @doc "The series' CalDAV document, repeating by `rule`, with `overrides` (the lines of `VEVENT`s) after its master."
  @spec caldav_series(String.t(), [String.t()]) :: String.t()
  def caldav_series(rule \\ "FREQ=WEEKLY;BYDAY=WE", overrides \\ []) do
    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        "UID:weekly-standup",
        "DTSTAMP:20260901T090000Z",
        "DTSTART:20260930T090000Z",
        "DTEND:20260930T100000Z",
        "RRULE:" <> rule,
        "SUMMARY:Weekly standup",
        "END:VEVENT"
      ] ++ overrides ++ ["END:VCALENDAR"],
      "\r\n"
    ) <> "\r\n"
  end

  @doc "A CalDAV calendar of `user`."
  @spec caldav_integration(map()) :: map()
  def caldav_integration(user) do
    insert(:calendar_integration,
      user: user,
      provider: "caldav",
      base_url: "https://caldav.example.com",
      calendar_paths: ["/cal/"]
    )
  end

  @doc "The 14 October occurrence of the CalDAV series, with `attrs`."
  @spec caldav_occurrence(map(), map()) :: map()
  def caldav_occurrence(integration, attrs \\ %{}) do
    occurrence(
      integration,
      Map.merge(
        %{
          provider: "caldav",
          provider_calendar_id: "/cal/",
          uid: "weekly-standup_20261014T090000",
          provider_event_id: "/cal/weekly-standup.ics",
          provider_metadata: %{"uid" => "weekly-standup"},
          etag: "\"etag-1\"",
          raw_ical: caldav_series()
        },
        attrs
      )
    )
  end

  @doc "The pattern the scope prompt says `scope` writes."
  @spec prompt_summary(Phoenix.LiveViewTest.View.t(), atom()) :: String.t()
  def prompt_summary(lv, scope),
    do: lv |> element("#recurrence-scope-#{scope} [data-role='scope-summary']") |> render()

  @doc "Opens `event` in the grid moved to `date`."
  @spec open(Plug.Conn.t(), map(), String.t()) :: Phoenix.LiveViewTest.View.t()
  def open(conn, event, date \\ "2026-10-14") do
    {:ok, lv, _html} = live(conn, "/dashboard/calendar")

    lv
    |> element("#calendar-grid")
    |> render_hook("navigate_to_day", %{"date" => date})

    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    assert has_element?(lv, @editor_form)
    lv
  end

  @doc "Changes the repeat editor's `fields`, answering the render."
  @spec pick(Phoenix.LiveViewTest.View.t(), map()) :: String.t()
  def pick(lv, fields), do: lv |> form(@editor_form, fields) |> render_change()

  @doc ~s(Presses "Save repeat".)
  @spec save(Phoenix.LiveViewTest.View.t()) :: String.t()
  def save(lv) do
    lv
    |> element("button[phx-click='save_event_recurrence']", "Save repeat")
    |> render_click()
  end

  @doc "Answers the scope prompt with `scope`."
  @spec confirm_scope(Phoenix.LiveViewTest.View.t(), String.t()) :: String.t()
  def confirm_scope(lv, scope) do
    lv
    |> element("#recurrence-prompt-modal [phx-value-scope='#{scope}']")
    |> render_click()
  end

  @doc "The Google series' recurring event."
  @spec google_master() :: map()
  def google_master do
    %{
      "id" => "series1",
      "iCalUID" => "series1@google.com",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "2026-09-30T09:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "2026-09-30T10:00:00Z", "timeZone" => "Etc/UTC"},
      "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=WE"]
    }
  end

  @doc "The Outlook series' master."
  @spec outlook_master() :: map()
  def outlook_master do
    %{
      "id" => "master-1",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "start" => %{"dateTime" => "2026-09-30T09:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-09-30T10:00:00.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => "UTC",
      "recurrence" => %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["wednesday"]},
        "range" => %{"type" => "noEnd", "startDate" => "2026-09-30"}
      }
    }
  end

  @doc "Answers every Google or Outlook request with `master`, or a new series for a create, and sends `{:request, method, url, body}` to the test."
  @spec serve(map()) :: :ok
  def serve(master) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})

      case method do
        :post ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "tail1"})}}

        :delete ->
          {:ok, %Req.Response{status: 204, body: ""}}

        _read_or_write ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(master)}}
      end
    end)
  end

  @doc "The next `count` requests `serve/1` reported, in order."
  @spec await_requests(pos_integer()) :: [{atom(), String.t(), term()}]
  def await_requests(count) do
    for _request <- 1..count do
      assert_receive {:request, method, url, body}, @timeout
      {method, url, body}
    end
  end

  @doc "Takes `count` CalDAV PUTs, each sent to the test as `{:put, url, body}`."
  @spec expect_puts(pos_integer()) :: term()
  def expect_puts(count) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, count, fn url, body, _headers, _opts ->
      send(test_pid, {:put, url, body})
      {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
    end)
  end

  @doc "The next `count` PUTs `expect_puts/1` took, in order."
  @spec await_puts(pos_integer()) :: [{String.t(), String.t()}]
  def await_puts(count) do
    for _put <- 1..count do
      assert_receive {:put, url, body}, @timeout
      {url, body}
    end
  end
end
