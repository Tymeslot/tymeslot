defmodule TymeslotWeb.CalendarSurfaceHelpers do
  @moduledoc """
  An organiser for the calendar's LiveView tests: clock on 24 hours, zone
  London, with one Google account holding a "Work" and a "Family" calendar.

  The clock is frozen at 08:00 UTC on Wednesday 14 October 2026 (09:00 in
  London), so "this week" is 12 to 18 October in every test that does not
  name a date. The frozen clock reaches the LiveView through `$callers`.

  Calendar fetches for availability answer "no events"
  (`TestMocks.stub_no_calendar_events/0`), so an organiser with an active
  meeting type gets its bookable layer computed without further stubs.

  Also the steps the side panel's New event tests share: opening a draft
  through quick create's More options, its form, and sending it as a
  Tymeslot meeting.
  """

  import ExUnit.Assertions
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CreatedEvent

  alias Plug.Conn
  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.TestMocks

  @now ~U[2026-10-14 08:00:00.000000Z]

  @doc "The frozen instant."
  @spec now() :: DateTime.t()
  def now, do: @now

  @doc """
  Signs in a new organiser. Options: `timezone` (default `"Europe/London"`),
  `preferences` (a keyword list merged into the stored calendar preferences).
  """
  @spec owner(Conn.t(), keyword()) :: %{conn: Conn.t(), user: map(), integration: map()}
  def owner(conn, opts \\ []) do
    ClockHelpers.freeze_clock(@now)
    TestMocks.stub_no_calendar_events()

    user = insert(:user, onboarding_completed_at: @now)
    insert(:profile, user: user, timezone: Keyword.get(opts, :timezone, "Europe/London"))

    preferences =
      Map.merge(
        %{time_format: "24h"},
        Map.new(Keyword.get(opts, :preferences, []))
      )

    {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, preferences)

    integration =
      insert(:calendar_integration,
        user: user,
        name: "Work account",
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "work", "name" => "Work", "selected" => true},
          %{"id" => "family", "name" => "Family", "selected" => true}
        ]
      )

    conn =
      conn
      |> Test.init_test_session(%{})
      |> Conn.fetch_session()
      |> log_in_user(user)

    %{conn: conn, user: user, integration: integration}
  end

  @doc "A synced, timed event on one of `integration`'s calendars."
  @spec event(map(), String.t(), String.t(), DateTime.t(), pos_integer(), keyword()) :: map()
  def event(integration, calendar_id, summary, start_at, minutes \\ 60, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          provider: "google",
          provider_calendar_id: calendar_id,
          summary: summary,
          start_at: start_at,
          end_at: DateTime.add(start_at, minutes, :minute),
          all_day: false,
          sync_state: "synced"
        ],
        attrs
      )
    )
  end

  @doc """
  Has the calendar provider take every create and tell `test_pid`, as
  `{:provider_call, task_pid, payload}`, or with `tag` given as
  `{:provider_call, task_pid, {tag, payload}}`.
  """
  @spec forward_creates(pid(), atom() | nil) :: :ok
  def forward_creates(test_pid, tag \\ nil) do
    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), if(tag, do: {tag, payload}, else: payload)})
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    :ok
  end

  @doc "Sends the calendar canvas hook's `event` with `params`."
  @spec canvas_push(term(), String.t(), map()) :: term()
  def canvas_push(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  @doc "The side panel's New event form."
  @spec new_event_form(term()) :: term()
  def new_event_form(lv), do: form(lv, "#calendar-panel-new-form")

  @doc "A titled one-hour draft on the Work calendar, as quick create sends it."
  @spec panel_draft(map(), map()) :: map()
  def panel_draft(integration, extra \\ %{}) do
    Map.merge(
      %{
        "draft" => "d1",
        "title" => "Lunch with Ada",
        "start" => "2026-10-15T13:00",
        "end" => "2026-10-15T14:00",
        "all_day" => false,
        "calendar" => "#{integration.id}:work",
        "location" => "",
        "guests" => [],
        "free" => false
      },
      extra
    )
  end

  @doc "Opens the New event panel on `panel_draft/2`; the reply is the caller's to read."
  @spec open_panel_draft(term(), map(), map()) :: term()
  def open_panel_draft(lv, integration, extra \\ %{}),
    do: canvas_push(lv, "calendar:more_options", panel_draft(integration, extra))

  @doc """
  Opens the New event panel on an untitled draft with two guests, Ada and
  Grace, and checks that it opened.
  """
  @spec open_meeting_draft(term(), map(), map()) :: term()
  def open_meeting_draft(lv, integration, extra \\ %{}) do
    canvas_push(
      lv,
      "calendar:more_options",
      panel_draft(
        integration,
        Map.merge(
          %{"title" => "", "guests" => ["ada@example.com", "grace@example.com"]},
          extra
        )
      )
    )

    assert_reply(lv, %{opened: true})
  end

  @doc "`count` distinct guest addresses."
  @spec guest_addresses(pos_integer()) :: [String.t()]
  def guest_addresses(count), do: Enum.map(1..count, &"guest#{&1}@example.com")

  @doc "Ticks \"Send as a Tymeslot meeting\"."
  @spec tick_meeting(term()) :: String.t()
  def tick_meeting(lv), do: render_change(new_event_form(lv), %{"meeting" => "true"})

  @doc "Clicks the meeting reminder preset `preset`, such as `\"1-hours\"`."
  @spec add_meeting_reminder(term(), String.t()) :: String.t()
  def add_meeting_reminder(lv, preset) do
    lv
    |> element(~s(#calendar-panel-meeting-reminders [data-testid="reminder-preset-#{preset}"]))
    |> render_click()
  end

  @doc """
  Traces what the dashboard process receives, so a test sees what the panel
  hands it (`{:trace, pid, :receive, message}`).
  """
  @spec trace_surface(term()) :: non_neg_integer()
  def trace_surface(lv), do: :erlang.trace(lv.pid, true, [:receive])

  @doc "Presses Create on a meeting draft, with Ada Lovelace as the guest's name."
  @spec book_meeting(term(), map()) :: String.t()
  def book_meeting(lv, extra \\ %{}) do
    render_submit(
      new_event_form(lv),
      Map.merge(%{"intent" => "create", "guest_name" => "Ada Lovelace"}, extra)
    )
  end
end
