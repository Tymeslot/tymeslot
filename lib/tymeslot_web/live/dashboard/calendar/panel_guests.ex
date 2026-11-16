defmodule TymeslotWeb.Dashboard.Calendar.PanelGuests do
  @moduledoc """
  The guests of the event the side panel shows, and telling them about the
  panel's changes.

  Inviting and removing write the guest list through `Writes.update/5`, to
  the event the panel shows, and email the guest concerned only once the
  calendar has accepted that write: an invitation for a new guest, a
  cancellation for a removed one (`membership_written/3`, from
  `Tymeslot.Meetings.AttendeeNotifications.membership_changed/3`). A write
  that fails emails nobody, so no guest is invited to an event they are not
  on, or told they are off one they are still on, and the toast naming the
  change waits for it too. Neither pushes an undo entry, since the email
  cannot be taken back. Removing asks
  first (`RemoveGuestModal`). An event a group meeting with live seats sits
  on refuses both (`EditGuard.check/3`), as does an event someone else
  organises (`EditGuard.guest_update/3`).

  Panel edits tell nobody on their own. `untold?/2` says whether the event
  has guests and differs, in anything they would see, from the event as the
  panel opened on it (`panel.opened_with`); `tell/1` sends one update for
  all of it and makes the event as it is now the new starting point. Only
  the organiser of an event on a calendar they can write may tell its
  guests; the domain refuses anyone else (`Changes.tell_guests/5`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Meetings.AttendeeNotifications
  alias TymeslotWeb.Dashboard.Calendar.Creation
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

  @doc "Invites `raw` to the event the panel shows: saves the list, then emails them."
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

      socket
      |> write(event, guests)
      |> assign(:guest_form_key, socket.assigns.guest_form_key + 1)
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
         :ok <- guest_gate(socket, event),
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

  @doc "Removes the guest the open prompt names: saves the list, then emails them."
  @spec confirm_remove(socket()) :: socket()
  def confirm_remove(%{assigns: %{remove_guest_prompt: %{email: email, event_id: id}}} = socket) do
    socket = assign(socket, :remove_guest_prompt, nil)

    with %{event_id: ^id} <- socket.assigns.panel,
         {:ok, event} <- Map.fetch(socket.assigns.events_by_id, id),
         :ok <- gates(socket, event),
         {[_first | _rest], kept} <- Enum.split_with(of(event), &(&1.email == email)) do
      write(socket, event, kept)
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
  removed since were told once their write was accepted, so the guest lists are left out
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
  write is saving, since the update reads the saved event. Only the
  organiser of an event on a calendar they can write may send it
  (`Changes.tell_guests/5` refuses anything else).
  """
  @spec tell(socket()) :: socket()
  def tell(socket) do
    with {:ok, event} <- panel_event(socket),
         :ok <- idle(socket, event),
         %{opened_with: opened_with} = panel <- socket.assigns.panel,
         true <- untold?(opened_with, event),
         false <- Writes.saving?(socket, event),
         {:ok, _sent_or_noop} <- send_update(socket, panel, event) do
      socket
      |> assign(:panel, %{panel | opened_with: event})
      |> Toast.show(dgettext("dashboard_calendar_editing", "Guests will get an update."))
    else
      true ->
        flash(
          socket,
          {:warning,
           dgettext("dashboard_calendar_editing", "Still saving. Tell guests once it has saved.")}
        )

      {:error, _reason} = refusal ->
        tell_refused(socket, refusal)

      _nothing_to_tell ->
        socket
    end
  end

  defp send_update(socket, panel, event),
    do:
      Changes.tell_guests(
        socket.assigns.current_user.id,
        socket.assigns.integrations,
        panel.opened_with,
        event,
        Map.get(panel, :scope)
      )

  defp tell_refused(socket, {:error, reason} = refusal)
       when reason in [:moving, :read_only, :unauthorized, :booking, :not_organiser],
       do: refuse(socket, refusal)

  defp tell_refused(socket, {:error, _reason}),
    do:
      flash(
        socket,
        {:warning,
         dgettext("dashboard_calendar_editing", "Couldn't tell guests. Your changes are saved.")}
      )

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
        {:invalid, Creation.guest_message(:organiser)}

      {:error, :guests, _reason} ->
        {:invalid, Creation.guest_message(:invalid)}
    end
  end

  # Providers keep the case an address was stored with, but the mailbox is
  # the same whatever its case.
  defp new_guest(event, email) do
    if Enum.any?(of(event), &(is_binary(&1.email) and String.downcase(&1.email) == email)),
      do: {:invalid, Creation.guest_message({:duplicate, email})},
      else: :ok
  end

  defp room_for_one_more(event) do
    max = CreateParams.max_guests()

    if length(of(event)) >= max,
      do:
        {:invalid,
         dngettext(
           "dashboard_calendar_editing",
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

  # Inviting and removing email the guest concerned, so they are the
  # organiser's alone, as telling guests is (`EditGuard.guest_update/3`).
  defp gates(socket, event) do
    with :ok <- idle(socket, event),
         :ok <- guest_gate(socket, event),
         do: EditGuard.check(socket.assigns.current_user.id, socket.assigns.integrations, event)
  end

  defp guest_gate(socket, event),
    do: EditGuard.guest_update(socket.assigns.current_user.id, socket.assigns.integrations, event)

  @doc "Why the guests of an event someone else organises are not emailed from here."
  @spec not_organiser_message() :: String.t()
  def not_organiser_message,
    do:
      dgettext(
        "dashboard_calendar_editing",
        "Someone else organises this event, so only they can email its guests."
      )

  @doc """
  Emails the guests a write the calendar accepted added to the event or
  removed from it (`AttendeeNotifications.membership_changed/3`), from
  `original_event`, the event as the write found it, and `updated_event`, as
  it left it, then tells the organiser: the toast names whom it invited or
  removed, and a warning says when an email could not be sent. Only now,
  so nothing is claimed for a write the calendar refused. A write saved to
  sync later has its emails held until the replay reaches the calendar, and
  the toast says so.
  """
  @spec membership_written(socket(), map(), map()) :: socket()
  def membership_written(socket, original_event, updated_event) do
    %{added: added, removed: removed} =
      AttendeeNotifications.membership_changed(
        original_event,
        updated_event,
        socket.assigns.current_user.id
      )

    before = emails(original_event)
    now = emails(updated_event)

    socket
    |> told(added, now -- before, &invited_toast/2, &invitation_failed/0)
    |> told(removed, before -- now, &removed_toast/2, &cancellation_failed/0)
  end

  # Gates refuse guests of an event someone else organises before any write
  # (`EditGuard.guest_update/3`), so a membership email is `:sent`,
  # `:after_sync`, `:noop` or failed here.
  defp told(socket, {:ok, sent}, [_first | _rest] = changed, toast, _failed)
       when sent in [:sent, :after_sync],
       do: Toast.show(socket, toast.(Enum.join(changed, ", "), sent))

  defp told(socket, {:error, _reason}, _changed, _toast, failed),
    do: flash(socket, {:warning, failed.()})

  defp told(socket, _noop, _changed, _toast, _failed), do: socket

  defp emails(event),
    do:
      event
      |> of()
      |> Enum.map(&(&1.email && String.downcase(String.trim(&1.email))))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

  defp invited_toast(emails, :sent),
    do: dgettext("dashboard_calendar_editing", "Invited %{email}.", email: emails)

  defp invited_toast(emails, :after_sync),
    do:
      dgettext(
        "dashboard_calendar_editing",
        "Added %{email}. They will be invited once the change has synced to your calendar.",
        email: emails
      )

  defp removed_toast(emails, :sent),
    do: dgettext("dashboard_calendar_editing", "Removed %{email}.", email: emails)

  defp removed_toast(emails, :after_sync),
    do:
      dgettext(
        "dashboard_calendar_editing",
        "Removed %{email}. They will be told once the change has synced to your calendar.",
        email: emails
      )

  defp invitation_failed,
    do:
      dgettext(
        "dashboard_calendar_events",
        "Attendee added, but their invitation could not be sent."
      )

  defp cancellation_failed,
    do:
      dgettext(
        "dashboard_calendar_events",
        "Attendee removed, but they could not be notified."
      )

  # The panel's header follows this write like any of its own
  # (`PanelStatus.started/2`, settled by `PanelEdits.settled/3`). The guests
  # it adds or removes are emailed once it is accepted (`membership_written/3`).
  defp write(socket, event, guests) do
    optimistic = %{event | attendees: guests}

    {socket, ref} =
      Writes.update(socket, event, optimistic, %{attendees: guests}, notify: :membership)

    PanelState.update(socket, &PanelStatus.started(%{&1 | event: optimistic}, ref))
  end

  defp refuse(socket, {:error, :moving}),
    do:
      PanelState.update(
        socket,
        &PanelStatus.refused(&1, CalendarEditMessages.moving_message())
      )

  defp refuse(socket, {:error, :not_organiser}),
    do: flash(socket, {:warning, not_organiser_message()})

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
