defmodule TymeslotWeb.Themes.Shared.GuestBooking do
  @moduledoc """
  Socket-state orchestration for the booking form's "add guests" field.

  Owns the in-flight guest list while the invitee fills in the booking form:
  adding (with inline validation), removing, and tracking the draft input.
  The committed list lives in the `:guest_emails` assign; the booking
  submission reads it from there.

  Client-side validation here is for fast UX feedback only — the authoritative
  sanitisation (self-exclusion, de-dup, cap) is re-applied server-side in
  `Tymeslot.Meetings.Guests.sanitize_emails/2` before persistence.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Meetings.Guests
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias TymeslotWeb.Components.MeetingUtils

  @doc "Initial assigns for the guest field, set once at scheduling mount."
  @spec assign_defaults(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_defaults(socket) do
    socket
    |> assign(:guest_emails, [])
    |> assign(:guest_input, "")
    |> assign(:guest_error, nil)
    |> assign(:guests_open, false)
    |> assign(:max_guests, Guests.max_guests())
  end

  @doc "Tracks the draft guest email as the invitee types."
  @spec set_input(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def set_input(socket, value), do: assign(socket, :guest_input, to_string(value))

  @doc "Reveals the guest field from its collapsed state."
  @spec open(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket), do: assign(socket, :guests_open, true)

  @doc """
  Collapses the guest field back to its "+ Add guests" call to action.

  Clears any in-flight guests and the draft input — the close (×) control
  abandons the guest section entirely, so the field is reset to its initial
  state.
  """
  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    socket
    |> assign(:guests_open, false)
    |> assign(:guest_emails, [])
    |> assign(:guest_input, "")
    |> assign(:guest_error, nil)
  end

  @doc """
  Validates and adds a guest email to the in-flight list.

  Returns the socket with `:guest_emails` extended and the input cleared on
  success, or `:guest_error` set (and the draft preserved) on a validation
  failure.
  """
  @spec add(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def add(socket, raw_email) do
    email = normalize(raw_email)
    emails = socket.assigns[:guest_emails] || []

    case validate(email, emails, socket) do
      :ok ->
        socket
        |> assign(:guest_emails, emails ++ [email])
        |> assign(:guest_input, "")
        |> assign(:guest_error, nil)

      {:error, message} ->
        assign(socket, :guest_error, message)
    end
  end

  @doc """
  Returns whether the booking form should show the guest field.

  Guests are allowed when the meeting type has `allow_guests: true` and the
  current flow is not a reschedule (adding guests to an existing meeting is
  not supported). Hidden outright once the seat cap has been driven to zero
  (the last seat on a group slot) — there is no room for a guest at all.
  """
  @spec guests_allowed?(map()) :: boolean()
  def guests_allowed?(%{max_guests: 0}), do: false

  def guests_allowed?(assigns) do
    case assigns[:meeting_type] do
      %{allow_guests: true} -> assigns[:is_rescheduling] != true
      _other -> false
    end
  end

  @doc """
  Recomputes the `:max_guests` assign from the seats left on the selected slot,
  trimming any guests the new slot has no room for.

  Call whenever the booker commits to a slot (booking-step entry) and after a
  live seat refresh — the cap must always reflect the seats the booker can
  actually still claim beyond their own.

  The trim matters as much as the cap. A booker who added three guests while
  five seats were free, and then lost seats to other bookers, would otherwise
  carry all three into every later slot: the seat transaction refuses
  `1 + guests` over capacity, so every slot small enough would bounce back as
  "no longer available" without ever mentioning guests. Dropping the guests
  that no longer fit — newest first, since the earliest invited are the ones
  the booker chose first — keeps the list honest and the error truthful.
  """
  @spec assign_seat_cap(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_seat_cap(socket) do
    cap = seat_cap(socket.assigns)
    kept = Enum.take(socket.assigns[:guest_emails] || [], cap)

    socket
    |> assign(:max_guests, cap)
    |> assign(:guest_emails, kept)
    |> assign(:guest_error, trim_notice(socket.assigns[:guest_emails] || [], kept))
  end

  defp trim_notice(before, kept) when length(before) > length(kept) do
    dgettext(
      "booking",
      "This time only has room for %{count} of your guests, so the rest were removed.",
      count: length(kept)
    )
  end

  defp trim_notice(_before, _kept), do: nil

  @doc """
  Effective guest cap: `min(Guests.max_guests(), seats_left - 1)` for group
  meeting types with a known selected slot, the flat cap otherwise.
  """
  @spec seat_cap(map()) :: non_neg_integer()
  def seat_cap(assigns) do
    with %{} = meeting_type <- assigns[:meeting_type],
         true <- MeetingTypeSchema.group?(meeting_type),
         %{seats_left: seats_left} when is_integer(seats_left) <- selected_slot(assigns) do
      max(min(Guests.max_guests(), seats_left - 1), 0)
    else
      _other -> Guests.max_guests()
    end
  end

  defp selected_slot(%{selected_time: time} = assigns) when is_binary(time) do
    assigns[:available_slots]
    |> MeetingUtils.normalize_slot_list()
    |> Enum.find(&(&1.time == time))
  end

  defp selected_slot(_assigns), do: nil

  @doc "Removes a guest email from the in-flight list."
  @spec remove(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def remove(socket, email) do
    target = normalize(email)
    emails = Enum.reject(socket.assigns[:guest_emails] || [], &(&1 == target))

    socket
    |> assign(:guest_emails, emails)
    |> assign(:guest_error, nil)
  end

  defp validate("", _emails, _socket), do: {:error, blank_message()}

  defp validate(email, emails, socket) do
    max_guests = socket.assigns[:max_guests] || Guests.max_guests()

    cond do
      length(emails) >= max_guests ->
        {:error,
         dngettext(
           "booking",
           "You can add up to %{count} guest.",
           "You can add up to %{count} guests.",
           max_guests,
           count: max_guests
         )}

      email in emails ->
        {:error, dgettext("booking", "%{email} has already been added.", email: email)}

      primary_email?(socket, email) ->
        {:error, dgettext("booking", "You don't need to add your own email as a guest.")}

      EmailValidator.validate(email) != :ok ->
        {:error, dgettext("booking", "Enter a valid email address.")}

      true ->
        :ok
    end
  end

  defp blank_message, do: dgettext("booking", "Enter a valid email address.")

  defp primary_email?(socket, email) do
    case socket.assigns[:form] do
      %{params: %{"email" => primary}} when is_binary(primary) -> normalize(primary) == email
      _other -> false
    end
  end

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
