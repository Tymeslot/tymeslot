defmodule Tymeslot.Dev.EmptyCalendar do
  @moduledoc """
  Development-only calendar stub.

  Compiled only in `:dev` (see the `dev/support` entry in `elixirc_paths/1` in
  `mix.exs`) and never bundled into release builds. It is **not** active by
  default — opt in by setting `DEV_EMPTY_CALENDAR=1`, which wires it in via
  `config :tymeslot, :calendar_module` in `config/dev.exs`.

  When active, every working-hours slot resolves as free: availability is
  computed instantly with no busy events and without contacting a real
  CalDAV/Google/Outlook server. This is for working on the booking UI and
  scheduling themes against a seeded demo organiser that has no real calendar
  connection. To exercise genuine calendar sync locally, leave the variable
  unset and the real `Calendar.Operations` module is used.
  """

  @behaviour Tymeslot.Integrations.Calendar.CalendarBehaviour

  @impl true
  def list_events_in_range(_user_id, _start_time, _end_time), do: {:ok, []}

  @impl true
  def get_events_for_range_fresh(_user_id, _start_date, _end_date), do: {:ok, []}

  @impl true
  def get_events_for_month(_user_id, _year, _month, _timezone), do: {:ok, []}

  @impl true
  def get_event(_uid, _user_id), do: {:error, :not_found}

  @impl true
  def create_event(_event_data, _context), do: {:ok, %{uid: "dev-stub-event"}}

  @impl true
  def update_event(_uid, _event_data, _context), do: :ok

  @impl true
  def delete_event(_uid, _context), do: :ok

  @impl true
  def get_booking_integration_info(_context), do: {:error, :no_integration}
end
