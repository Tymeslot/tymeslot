defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.ExtraGuests do
  @moduledoc """
  The extra guests of the calendar grid's create form: whether an address
  can join them, and the names typed with them (`Name <address>`, as a
  contact suggestion fills it in), kept by address under `:guest_names`.

  Pure functions over the form's `creating_event` map; the handlers in
  `TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormState` and the
  save in `CreateExecution` apply them.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Validation.AddressList
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  @doc """
  Whether `email` (already trimmed and downcased) can join the meeting's extra
  guests, or the reason it cannot. Save runs the same check over an address
  still sitting in the input, so the two cannot disagree.

  The host's own address (`organizer_email`) is refused: they organise the
  meeting and are never one of its guests. The main guest's address only
  counts while the meeting has a main participant; without one, whatever is
  left in that hidden field invites nobody.
  """
  @spec check(map(), String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def check(creating, email, organizer_email) do
    cond do
      not Shared.valid_email?(email) ->
        {:error,
         dgettext("dashboard_calendar_events", "%{email} is not a valid email address.",
           email: email
         )}

      same_address?(email, organizer_email) ->
        {:error,
         dgettext(
           "dashboard_calendar_events",
           "You cannot add yourself as a guest. Use a different email address."
         )}

      Map.get(creating, :main_participant, true) and
          email == creating.guest_email |> String.trim() |> String.downcase() ->
        {:error,
         dgettext("dashboard_calendar_events", "%{email} is already the main guest.",
           email: email
         )}

      email in creating.guest_emails ->
        {:error,
         dgettext("dashboard_calendar_events", "%{email} is already invited.", email: email)}

      length(creating.guest_emails) >= Guests.max_guests() ->
        {:error,
         dgettext("dashboard_calendar_events", "No more guests can be added to this meeting.")}

      true ->
        :ok
    end
  end

  @doc """
  Whether two addresses are the same mailbox, compared trimmed and
  case-insensitively as `Tymeslot.Bookings.CreateAdHoc` compares a
  self-booking.
  """
  @spec same_address?(String.t() | nil, String.t() | nil) :: boolean()
  def same_address?(left, right) when is_binary(left) and is_binary(right),
    do: normalise_address(left) == normalise_address(right)

  def same_address?(_left, _right), do: false

  defp normalise_address(email), do: email |> String.trim() |> String.downcase()

  @doc """
  Records the name typed with an extra guest's address, when it is one a
  guest could be given.
  """
  @spec put_name(map(), AddressList.entry()) :: map()
  def put_name(creating, %{email: email, name: name} = entry) do
    if is_binary(name) and AddressList.valid_name?(entry),
      do: Map.update(creating, :guest_names, %{email => name}, &Map.put(&1, email, name)),
      else: creating
  end

  @doc "Forgets the name of a guest taken off the meeting."
  @spec forget_name(map(), String.t()) :: map()
  def forget_name(creating, email),
    do: Map.update(creating, :guest_names, %{}, &Map.delete(&1, email))
end
