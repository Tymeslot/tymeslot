defmodule Tymeslot.WeekViewTestHelpers do
  @moduledoc """
  Drives a schedule step that shows the shared week grid
  (`TymeslotWeb.Themes.Shared.Components.WeekGrid`) in a LiveView test, for
  the flow helpers that pick a time whatever picker the page shows
  (`Tymeslot.ThemeBookingFlowHelpers`, `Tymeslot.BookingTestHelpers`).

  LiveViewTest runs no JS bindings, so the grid's own `load_week` (sent from
  its `phx-mounted` and `phx-connected`) is sent here by hand, once the
  month's availability has arrived and the page has landed the booker on
  their first free day: that landing can move the week
  (`TymeslotWeb.Live.Scheduling.WeekSlots.follow_week/1`), and times read
  before it may belong to a week the page then leaves. The waits read the
  LiveView's assigns, as the landing's own flow tests do, because nothing on
  the page says the landing is over.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.LiveViewTest

  alias Tymeslot.TestHelpers.Eventually

  @week_grid "[data-testid='week-grid']"
  @schedule_step "[data-phx-component]:has([data-testid='week-grid'])"
  @free_slot "button[data-testid='week-slot']:not([disabled])"
  @max_weeks 6

  @doc "Whether the schedule step on screen is a week grid."
  @spec week_view?(Phoenix.LiveViewTest.View.t()) :: boolean()
  def week_view?(view), do: has_element?(view, @week_grid)

  @doc """
  Loads the week on screen as the grid's bindings would, once the month's
  availability is in, and waits until that week is on screen.
  """
  @spec load_week(Phoenix.LiveViewTest.View.t()) :: :ok
  def load_week(view) do
    wait(fn -> live_assigns(view)[:availability_status] in [:loaded, :error] end)
    view |> with_target(@schedule_step) |> render_click("load_week", %{})
    await_week(view)
  end

  @doc "Waits until the week on screen is the week last fetched and its fetch is done."
  @spec await_week(Phoenix.LiveViewTest.View.t()) :: :ok
  def await_week(view) do
    wait(fn ->
      render_async(view)
      week_shown?(live_assigns(view))
    end)

    :ok
  end

  @doc """
  Loads the week and picks the first free time the grid offers, moving on a
  week at a time (at most #{@max_weeks} weeks) while the week on screen has
  none. Returns the day and the time, `{iso_date, time}`.
  """
  @spec select_first_slot(Phoenix.LiveViewTest.View.t()) :: {String.t(), String.t()}
  def select_first_slot(view) do
    load_week(view)
    pick_first(view, @max_weeks)
  end

  @doc """
  Loads the week, shows the week holding `date` and picks the first free time
  on that day. Returns the time.
  """
  @spec select_first_slot_on(Phoenix.LiveViewTest.View.t(), Date.t()) :: String.t()
  def select_first_slot_on(view, %Date{} = date) do
    load_week(view)
    show_week_of(view, date, @max_weeks)

    on_day = "#{@free_slot}[data-date='#{Date.to_iso8601(date)}']"

    time =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute(on_day, "data-time")
      |> List.first() || flunk("Expected a free time on #{date} in the week grid")

    view |> element("#{on_day}[data-time='#{time}']") |> render_click()
    time
  end

  defp pick_first(_view, 0),
    do: flunk("Expected a free time in the week grid within #{@max_weeks} weeks")

  defp pick_first(view, weeks_left) do
    case view |> render() |> Floki.parse_document!() |> Floki.find(@free_slot) do
      [slot | _rest] ->
        [date] = Floki.attribute(slot, "data-date")
        [time] = Floki.attribute(slot, "data-time")

        view
        |> element("#{@free_slot}[data-date='#{date}'][data-time='#{time}']")
        |> render_click()

        {date, time}

      [] ->
        move(view, "week-grid-next")
        pick_first(view, weeks_left - 1)
    end
  end

  defp show_week_of(_view, date, 0),
    do: flunk("The week grid never showed the week of #{date}")

  defp show_week_of(view, date, steps_left) do
    case Date.compare(live_assigns(view).current_week_start, Date.beginning_of_week(date)) do
      :eq ->
        :ok

      :lt ->
        move(view, "week-grid-next")
        show_week_of(view, date, steps_left - 1)

      :gt ->
        move(view, "week-grid-prev")
        show_week_of(view, date, steps_left - 1)
    end
  end

  defp move(view, testid) do
    view |> element("button[data-testid='#{testid}']") |> render_click()
    await_week(view)
  end

  defp week_shown?(%{
         week_slots: %{},
         week_slots_start: week,
         current_week_start: week,
         week_slots_loading: false
       }),
       do: true

  defp week_shown?(_assigns), do: false

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp wait(fun), do: Eventually.eventually(fun, timeout: 5000, interval: 50)
end
