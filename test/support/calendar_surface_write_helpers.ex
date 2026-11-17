defmodule TymeslotWeb.CalendarSurfaceWriteHelpers do
  @moduledoc """
  Drives the calendar's event writes from a LiveView test: every write
  to the calendar is held until the test answers it, and the side panel's
  steps of editing an event.

  `hold_writes/0` stubs `Tymeslot.CalendarMock.update_event/3` to send
  `{:write_started, write, uid, payload}` to the test and wait; `answer/2`
  releases `write` with the result the calendar gives.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  @endpoint TymeslotWeb.Endpoint

  @doc "Holds every calendar write until the test answers it."
  @spec hold_writes() :: :ok
  def hold_writes do
    test_pid = self()

    Mox.stub(Tymeslot.CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:write_started, self(), uid, payload})

      receive do
        {:answer, answer} -> answer
      end
    end)

    :ok
  end

  @doc "Opens the calendar on `conn` with `event` in the side panel."
  @spec open_event(Plug.Conn.t(), map()) :: term()
  def open_event(conn, event) do
    {:ok, lv, _html} = live(conn, "/dashboard/calendar")
    open_panel(lv, event)
  end

  @doc "Opens `event` in the side panel of the calendar `lv` shows."
  @spec open_panel(term(), map()) :: term()
  def open_panel(lv, event) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{event.id}"})

    lv
  end

  @doc "Renames the event open in the panel, as leaving the title field does."
  @spec rename(term(), String.t()) :: String.t()
  def rename(lv, title),
    do: lv |> element("#calendar-panel-title") |> render_blur(%{"value" => title})

  @doc "Changes the place of the event open in the panel."
  @spec relocate(term(), String.t()) :: String.t()
  def relocate(lv, place),
    do: lv |> element("#calendar-panel-location") |> render_blur(%{"value" => place})

  @doc "Kills the LiveView outright, as a dropped connection eventually does."
  @spec kill(term()) :: true
  def kill(lv) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(lv.pid)
    Process.exit(lv.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 5_000
  end

  @doc """
  Answers the held write and waits for its task to finish, by which time
  the result is on its way to the LiveView.
  """
  @spec answer(pid(), term()) :: term()
  def answer(write, answer) do
    ref = Process.monitor(write)
    send(write, {:answer, answer})
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
  end

  @doc """
  The LiveView hands a write's result on to the surface with `send_update/2`,
  a message to itself queued behind whatever else is waiting, so the first
  render only lets that update through and the second one shows it.
  """
  @spec settled(term()) :: String.t()
  def settled(lv) do
    render(lv)
    render(lv)
  end
end
