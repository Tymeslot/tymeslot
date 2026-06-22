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
  alias Tymeslot.Security.FieldValidators.EmailValidator

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
  not supported).
  """
  @spec guests_allowed?(map()) :: boolean()
  def guests_allowed?(assigns) do
    case assigns[:meeting_type] do
      %{allow_guests: true} -> assigns[:is_rescheduling] != true
      _other -> false
    end
  end

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
    cond do
      length(emails) >= Guests.max_guests() ->
        {:error,
         dgettext("booking", "You can add up to %{count} guests.", count: Guests.max_guests())}

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
