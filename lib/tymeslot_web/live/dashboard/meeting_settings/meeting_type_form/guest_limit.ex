defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GuestLimit do
  @moduledoc """
  The meeting-type form's limit on the guests one booking may bring
  (`max_guests_per_booking`), shown under the guests switch: off keeps the
  overall limit (`Tymeslot.Meetings.Guests.max_guests/0`), on takes a number
  in `Constraints.guests_per_booking_range/0`. Held as the form's
  `:guest_limit` assign, `nil` while off.
  """

  alias Phoenix.Component
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Autosave

  # Turning the limit on starts at a single guest, the common case for a
  # group session where each booker may bring one companion.
  @default_limit 1

  @doc "Turns the limit on at its starting value, or off."
  @spec toggle(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle(socket) do
    limit = if is_nil(socket.assigns[:guest_limit]), do: @default_limit

    socket
    |> Component.assign(:guest_limit, limit)
    |> Autosave.maybe_run()
  end

  @doc """
  Takes the limit from its input. The input is bounded by its own min and
  max, so a value outside them is clamped rather than refused, and one that
  is not a number is ignored.
  """
  @spec change(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def change(%{"meeting_type" => %{"guest_limit_input" => value}}, socket) do
    case Integer.parse(to_string(value)) do
      {count, ""} ->
        range = Constraints.guests_per_booking_range()

        socket
        |> Component.assign(:guest_limit, count |> max(range.first) |> min(range.last))
        |> Autosave.maybe_run()

      _not_a_number ->
        socket
    end
  end

  def change(_params, socket), do: socket

  @doc "How many guests the form's current setting allows a booking."
  @spec effective(pos_integer() | nil) :: pos_integer()
  def effective(guest_limit), do: Guests.limit_for(%{max_guests_per_booking: guest_limit})
end
