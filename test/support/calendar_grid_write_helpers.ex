defmodule TymeslotWeb.CalendarGridWriteHelpers do
  @moduledoc """
  Drives the calendar grid's event writes from a LiveView test: an organiser
  with a calendar whose every write is held until the test answers it, an
  event on today's grid, and the steps of editing it.

  `hold_writes/1` stubs `Tymeslot.CalendarMock.update_event/3` to send
  `{:write_started, write, uid, payload}` to the test and wait; `answer/2`
  releases `write` with the result the calendar gives.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [get: 2, init_test_session: 2]
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [fetch_session: 1]
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  @endpoint TymeslotWeb.Endpoint

  @doc """
  An organiser logged in on `conn`, with an active calendar whose writes
  are held until the test answers them.
  """
  @spec hold_writes(map()) :: {:ok, keyword()}
  def hold_writes(%{conn: conn}) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    integration = insert(:calendar_integration, user: user, is_active: true)

    test_pid = self()

    Mox.stub(Tymeslot.CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:write_started, self(), uid, payload})

      receive do
        {:answer, answer} -> answer
      end
    end)

    {:ok, conn: conn, user: user, integration: integration}
  end

  @doc "An hour-long event of `integration` today, starting at `time`."
  @spec standup(map(), String.t(), String.t(), Time.t()) :: map()
  def standup(integration, summary, location, time \\ ~T[10:00:00]) do
    today = Date.utc_today()

    insert(:provider_calendar_event, %{
      calendar_integration: integration,
      summary: summary,
      location: location,
      start_at: DateTime.new!(today, time, "Etc/UTC"),
      end_at: DateTime.new!(today, Time.add(time, 3600), "Etc/UTC"),
      all_day: false
    })
  end

  @doc "Opens the calendar grid on `conn` with `event` selected."
  @spec open_event(Plug.Conn.t(), map()) :: term()
  def open_event(conn, event) do
    {:ok, lv, _html} = live(conn, "/dashboard/calendar")
    lv |> element("[id^='event-#{event.id}-']") |> render_click()
    lv
  end

  @doc "Makes the inline edit `event_name` of the selected event."
  @spec edit(term(), String.t(), String.t()) :: String.t()
  def edit(lv, event_name, value),
    do: lv |> element("#calendar-grid") |> render_hook(event_name, %{"value" => value})

  @doc "Kills the LiveView outright, as a dropped connection eventually does."
  @spec kill(term()) :: true
  def kill(lv) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(lv.pid)
    Process.exit(lv.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 1_000
  end

  @doc """
  Answers the held write and waits for its task to finish, by which time
  the result is on its way to the LiveView.
  """
  @spec answer(pid(), term()) :: term()
  def answer(write, answer) do
    ref = Process.monitor(write)
    send(write, {:answer, answer})
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000
  end

  @doc """
  The LiveView hands a write's result on to the grid with `send_update/2`,
  a message to itself queued behind whatever else is waiting, so the first
  render only lets that update through and the second one shows it.
  """
  @spec settled(term()) :: String.t()
  def settled(lv) do
    render(lv)
    render(lv)
  end
end
