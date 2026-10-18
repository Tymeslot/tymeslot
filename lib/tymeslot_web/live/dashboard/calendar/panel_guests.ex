defmodule TymeslotWeb.Dashboard.Calendar.PanelGuests do
  @moduledoc """
  The guests of the event the side panel shows, and telling them about the
  panel's changes.

  Inviting and removing email the guest concerned at once, as the old
  calendar does: an invitation for a new guest, a cancellation for a removed
  one (`Tymeslot.Meetings.AttendeeNotifications`). The guest list is then
  written through `Writes.update/5`, to the event the panel shows, as the
  old calendar writes it; neither pushes an undo entry, since the email
  cannot be taken back. Removing asks first (`RemoveGuestModal`). An event a
  group meeting with live seats sits on refuses both (`EditGuard.check/3`).

  Panel edits tell nobody on their own. `untold?/2` says whether the event
  has guests and differs, in anything they would see, from the event as the
  panel opened on it (`panel.opened_with`); `tell/1` sends one update for
  all of it and makes the event as it is now the new starting point.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Meetings.AttendeeNotifications
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.PanelStatus
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.Calendar.Writes
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "The event's guests in the canonical shape, for the chips and every write."
  @spec of(map()) :: [Attendee.t()]
  def of(event),
    do: event |> Map.get(:attendees) |> List.wrap() |> Enum.map(&Attendee.normalise/1)

  @doc "Invites `raw` to the event the panel shows: emails them, then saves the list."
  @spec invite(socket(), String.t()) :: socket()
  def invite(socket, raw) when is_binary(raw) do
    with {:ok, event} <- panel_event(socket),
         :ok <- idle(socket, event),
         {:ok, email} <- address(socket, raw),
         :ok <- new_guest(event, email),
         :ok <- room_for_one_more(event),
         :ok <- gates(socket, event) do
      added = Attendee.new(email: email)
      guests = of(event) ++ [added]
      {:ok, _sent} = AttendeeNotifications.attendees_added(event, [added])

      socket
      |> write(event, guests)
      |> assign(:guest_form_key, socket.assigns.guest_form_key + 1)
      |> Toast.show(dgettext("dashboard_calendar", "Invited %{email}.", email: email))
    else
      {:invalid, message} -> flash(socket, {:warning, message})
      refusal -> refuse(socket, refusal)
    end
  end

  def invite(socket, _raw), do: socket

  @doc "Asks whether to remove the guest `email` from the event the panel shows."
  @spec request_remove(socket(), String.t()) :: socket()
  def request_remove(socket, email) when is_binary(email) do
    with {:ok, event} <- panel_event(socket),
         true <- Enum.any?(of(event), &(&1.email == email)),
         :ok <- idle(socket, event),
         :ok <- EditGuard.writable(socket.assigns.integrations, event),
         :ok <- EditGuard.seat_lock(socket.assigns.current_user.id, event) do
      assign(socket, :remove_guest_prompt, %{
        email: email,
        event_id: socket.assigns.panel.event_id
      })
    else
      false -> socket
      refusal -> refuse(socket, refusal)
    end
  end

  def request_remove(socket, _email), do: socket

  @doc "Removes the guest the open prompt names: emails them, then saves the list."
  @spec confirm_remove(socket()) :: socket()
  def confirm_remove(%{assigns: %{remove_guest_prompt: %{email: email, event_id: id}}} = socket) do
    socket = assign(socket, :remove_guest_prompt, nil)

    with %{event_id: ^id} <- socket.assigns.panel,
         {:ok, event} <- Map.fetch(socket.assigns.events_by_id, id),
         :ok <- gates(socket, event),
         {[_first | _rest] = removed, kept} <- Enum.split_with(of(event), &(&1.email == email)) do
      {:ok, _sent} = AttendeeNotifications.attendees_removed(event, removed)

      socket
      |> write(event, kept)
      |> Toast.show(dgettext("dashboard_calendar", "Removed %{email}.", email: email))
    else
      {[], _kept} -> socket
      {:error, _reason} = refusal -> refuse(socket, refusal)
      {:error, :rate_limited, _message} = refusal -> refuse(socket, refusal)
      _gone -> socket
    end
  end

  def confirm_remove(socket), do: socket

  @doc "Closes the removal prompt; nothing has changed."
  @spec cancel_remove(socket()) :: socket()
  def cancel_remove(socket), do: assign(socket, :remove_guest_prompt, nil)

  @doc """
  Whether `event` has guests and differs, in anything they would see, from
  `opened_with`, the event as the panel opened on it. Guests added or
  removed since were told when it happened, so the guest lists are left out
  of the comparison.
  """
  @spec untold?(map() | nil, map() | nil) :: boolean()
  def untold?(%{} = opened_with, %{} = event) do
    case of(event) do
      [] ->
        false

      guests ->
        match?(
          {:needs_confirmation, _summary},
          AttendeeNotifications.event_updated(opened_with, event, guests)
        )
    end
  end

  def untold?(_opened_with, _event), do: false

  @doc """
  Tells the event's guests about everything changed since the panel opened,
  in one update, and counts from the event as it is now. Waits while a
  write is saving, since the update reads the saved event.
  """
  @spec tell(socket()) :: socket()
  def tell(socket) do
    with {:ok, event} <- panel_event(socket),
         :ok <- idle(socket, event),
         %{opened_with: opened_with} = panel <- socket.assigns.panel,
         true <- untold?(opened_with, event),
         false <- Writes.saving?(socket, event),
         :ok <- send_update(socket, panel, opened_with, event) do
      socket
      |> assign(:panel, %{panel | opened_with: event})
      |> Toast.show(dgettext("dashboard_calendar", "Guests will get an update."))
    else
      true ->
        flash(
          socket,
          {:warning,
           dgettext("dashboard_calendar", "Still saving. Tell guests once it has saved.")}
        )

      {:error, :moving} = refusal ->
        refuse(socket, refusal)

      {:error, _reason} ->
        flash(
          socket,
          {:warning,
           dgettext("dashboard_calendar", "Couldn't tell guests. Your changes are saved.")}
        )

      _nothing_to_tell ->
        socket
    end
  end

  # A series-wide scope's write drops the series' cached rows, which the
  # debounced update would read, so it is sent at once from both versions.
  defp send_update(socket, %{scope: scope}, opened_with, event)
       when scope in [:following, :all] do
    case AttendeeNotifications.series_updated_confirm(
           opened_with,
           event,
           socket.assigns.current_user.id,
           scope
         ) do
      {:ok, _sent_or_noop} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp send_update(_socket, _panel, opened_with, event) do
    guests = of(event)

    with {:needs_confirmation, summary} <-
           AttendeeNotifications.event_updated(opened_with, event, guests),
         {:ok, :sent} <- AttendeeNotifications.event_updated_confirm(event, summary, guests) do
      :ok
    end
  end

  defp panel_event(%{assigns: %{panel: %{mode: :edit, event_id: id}}} = socket),
    do: Map.fetch(socket.assigns.events_by_id, id)

  defp panel_event(_socket), do: :error

  # The create path's own check of guest addresses (trimmed, lower-cased,
  # valid, never the organiser's own), so inviting here and creating agree.
  defp address(socket, raw) do
    case CreateParams.guests(socket.assigns.current_user.id, [raw]) do
      {:ok, [email]} ->
        {:ok, email}

      {:ok, []} ->
        {:invalid,
         dgettext(
           "dashboard_calendar",
           "You're the organiser, so there's no need to invite yourself."
         )}

      {:error, :guests, _reason} ->
        {:invalid, dgettext("dashboard_calendar", "Enter a valid email address.")}
    end
  end

  # Providers keep the case an address was stored with, but the mailbox is
  # the same whatever its case.
  defp new_guest(event, email) do
    if Enum.any?(of(event), &(is_binary(&1.email) and String.downcase(&1.email) == email)),
      do:
        {:invalid, dgettext("dashboard_calendar", "%{email} is already a guest.", email: email)},
      else: :ok
  end

  defp room_for_one_more(event) do
    max = CreateParams.max_guests()

    if length(of(event)) >= max,
      do:
        {:invalid,
         dngettext(
           "dashboard_calendar",
           "An event can have at most %{count} guest.",
           "An event can have at most %{count} guests.",
           max
         )},
      else: :ok
  end

  # Guests are not changed while the event moves to another calendar: the
  # write would go to the calendar it is leaving.
  defp idle(socket, event),
    do: if(Transfer.moving?(socket, EventPayload.id(event)), do: {:error, :moving}, else: :ok)

  defp gates(socket, event) do
    with :ok <- idle(socket, event),
         do: EditGuard.check(socket.assigns.current_user.id, socket.assigns.integrations, event)
  end

  # The panel's header follows this write like any of its own
  # (`PanelStatus.started/2`, settled by `PanelEdits.settled/3`).
  defp write(socket, event, guests) do
    optimistic = %{event | attendees: guests}
    {socket, ref} = Writes.update(socket, event, optimistic, %{attendees: guests}, [])

    PanelState.update(socket, &PanelStatus.started(%{&1 | event: optimistic}, ref))
  end

  defp refuse(socket, {:error, :moving}),
    do:
      PanelState.update(
        socket,
        &PanelStatus.refused(&1, CalendarEditMessages.moving_message())
      )

  defp refuse(socket, {:error, _reason} = refusal),
    do: flash(socket, CalendarEditMessages.refusal(refusal))

  defp refuse(socket, {:error, :rate_limited, _message} = refusal),
    do: flash(socket, CalendarEditMessages.refusal(refusal))

  defp refuse(socket, _ignored), do: socket

  defp flash(socket, flash) do
    send(self(), {:flash, flash})
    socket
  end
end
