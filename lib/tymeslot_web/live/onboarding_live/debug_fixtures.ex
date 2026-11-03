defmodule TymeslotWeb.OnboardingLive.DebugFixtures do
  @moduledoc """
  Named states for the onboarding debug routes, chosen with `?fixture=<name>`.

  A fixture puts the wizard into a state that is slow or awkward to reach by
  hand (a connected calendar, a week preview that failed) so a step can be
  looked at in that state. It never writes to the database, and the
  LiveView applies it on the debug actions alone: on the real routes the
  parameter is ignored.

  Fixtures:

    * `calendar` - a bookable Google calendar is connected, and the stage
      reads the week as it would after a real connect (`WeekReveal`). There
      is no real calendar to read, so the week that arrives is the
      account's own hours with nothing busy.
    * `reveal_ready` - `calendar`, and the stage's week is ready: a fixed
      sample week (`sample_week/2`) with busy blocks on Tuesday 14:00-15:00
      and Thursday 10:00-11:30 and 23 open slots
    * `reveal_empty` - `calendar`, and the same week ready with no busy blocks
    * `reveal_slow` - `calendar`, and the week is taking too long to read
    * `reveal_failed` - `calendar`, and the week could not be read

  A week fixture stands in for the read: it cancels any read in flight and
  bumps `reveal_key`, so a real answer already on its way is dropped
  (`WeekReveal.handle_result/2`) and the times reveal as they would.

  Any other name, including ones reserved for fixtures still to come, leaves
  the socket as it is.
  """

  import Kernel, except: [apply: 2]

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Availability
  alias Tymeslot.Availability.WeekPreview
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias TymeslotWeb.OnboardingLive.WeekReveal

  @doc """
  Applies the fixture named `name` to the socket.
  """
  @spec apply(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def apply(socket, "calendar") do
    socket
    |> connect_fake_calendar()
    |> Component.assign(:stage_week, WeekReveal.initial_week(true))
    |> WeekReveal.maybe_start()
  end

  def apply(socket, "reveal_ready"), do: with_week(socket, :ready, busy: true)
  def apply(socket, "reveal_empty"), do: with_week(socket, :ready, busy: false)
  def apply(socket, "reveal_slow"), do: with_week(socket, :slow)
  def apply(socket, "reveal_failed"), do: with_week(socket, :failed)

  def apply(socket, _name), do: socket

  # Open slots per ISO weekday (1 is Monday), and the busy blocks between
  # them: 23 slots in any seven days in a row.
  @sample_slots %{
    1 => ~w(09:00 09:30 10:00 10:30 11:00),
    2 => ~w(13:00 13:30 15:00 15:30),
    3 => ~w(09:00 09:30 10:00 10:30 11:00),
    4 => ~w(09:00 09:30 11:30 12:00),
    5 => ~w(09:00 09:30 10:00 10:30 11:00)
  }

  @sample_busy %{2 => [{~T[14:00:00], ~T[15:00:00]}], 4 => [{~T[10:00:00], ~T[11:30:00]}]}

  @doc """
  The sample week the reveal fixtures show: seven days from `today`, with
  the same open slots and (when `busy` is set) busy blocks on each weekday
  whatever the date, so it always has 23 slots.
  """
  @spec sample_week(Date.t(), boolean()) :: WeekPreview.t()
  def sample_week(today, busy) do
    days =
      for offset <- 0..6 do
        date = Date.add(today, offset)
        weekday = Date.day_of_week(date)

        %{
          date: date,
          slots: Map.get(@sample_slots, weekday, []),
          busy: if(busy, do: Map.get(@sample_busy, weekday, []), else: [])
        }
      end

    %WeekPreview{
      days: days,
      slot_count: days |> Enum.map(&length(&1.slots)) |> Enum.sum(),
      first_busy:
        Enum.find_value(days, fn
          %{busy: [{start, _end} | _rest], date: date} -> %{date: date, start: start}
          _day -> nil
        end)
    }
  end

  defp with_week(socket, state, opts \\ []) do
    preview =
      if state == :ready,
        do: sample_week(Availability.today(socket.assigns[:profile]), opts[:busy])

    socket
    |> connect_fake_calendar()
    |> LiveView.cancel_async(:week_preview)
    |> Component.assign(
      stage_week: %{state: state, preview: preview},
      reveal_key: Map.get(socket.assigns, :reveal_key, 0) + 1
    )
  end

  defp connect_fake_calendar(socket) do
    Component.assign(socket,
      connected_calendars: [fake_calendar(socket.assigns)],
      booking_page_live: true
    )
  end

  # Never persisted, so it has no id; the calendar step reads only the
  # provider and the names shown on its connected row.
  defp fake_calendar(assigns) do
    %CalendarIntegrationSchema{
      name: "Google Calendar",
      provider: "google",
      provider_account_email: fake_email(assigns),
      is_active: true
    }
  end

  defp fake_email(%{current_user: %{email: email}}), do: email
  defp fake_email(_assigns), do: nil
end
