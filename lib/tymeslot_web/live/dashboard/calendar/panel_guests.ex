defmodule TymeslotWeb.Dashboard.Calendar.PanelGuests do
  @moduledoc """
  The guests of the event the side panel shows, and telling them about the
  panel's changes.

  An address the panel will not invite (not an email, the organiser's own,
  a guest already, past the limit) is said under the guest field.

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
  panel opened on it (`panel.opened_with`), or as it was before a drag or
  resize nobody was told about (`untold_moves`, see `Manipulation`); `tell/1`
  sends one update for all of it and makes the event as it is now the new
  starting point. Only
  the organiser of an event on a calendar they can write may tell its
  guests; the domain refuses anyone else (`Changes.tell_guests/5`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [send_update_after: 3]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Meetings.AttendeeNotifications
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.PanelStatus
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.Calendar.Writes
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  # How long after an update is due the panel looks whether it has gone out,
  # and the longest it waits between looks while the update is overdue.
  @hold_grace_ms 1_000
  @max_hold_backoff_ms 30_000

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
      |> PanelState.put_error("guest", nil)
      |> assign(:guest_form_key, socket.assigns.guest_form_key + 1)
    else
      {:invalid, message} -> PanelState.put_error(socket, "guest", message)
      refusal -> refuse(socket, refusal)
    end
  end

  def invite(socket, _raw), do: socket

  @doc "Typing in the guest field clears what it said about the last address."
  @spec typed(socket()) :: socket()
  def typed(%{assigns: %{panel: %{mode: :edit}}} = socket),
    do: PanelState.put_error(socket, "guest", nil)

  def typed(socket), do: socket

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
      held_until = Changes.guest_update_held_until(event)

      socket
      |> count_from_now(panel, event, held_until != nil)
      |> assign(:untold_moves, Map.delete(socket.assigns.untold_moves, panel.event_id))
      |> watch_hold(panel.event_id, held_until)
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

  @doc """
  Cancels the update "Tell guests" sent for the panel's event while it is
  still held, so the guests are told nothing, and counts the changes as
  untold again: the panel offers to tell them once more. An update that has
  gone out meanwhile cannot be taken back, and the organiser is told so.
  Only the event's organiser may (`Changes.cancel_guest_update/3`).
  """
  @spec cancel_pending(socket()) :: socket()
  def cancel_pending(socket) do
    with {:ok, event} <- panel_event(socket),
         %{guests_pending: true, held_until: %DateTime{} = held_until} = panel <-
           socket.assigns.panel,
         {:ok, outcome} <-
           Changes.cancel_guest_update(
             socket.assigns.current_user.id,
             socket.assigns.integrations,
             event,
             held_until
           ) do
      socket
      |> assign(:held_from, Map.delete(socket.assigns.held_from, panel.event_id))
      |> cancelled(panel, Map.get(socket.assigns.held_from, panel.event_id), outcome)
    else
      {:error, _reason} = refusal -> refuse(socket, refusal)
      _nothing_held -> socket
    end
  end

  defp cancelled(socket, panel, told_from, :cancelled),
    do:
      socket
      |> untold_again(panel, told_from)
      |> Toast.show(dgettext("dashboard_calendar_editing", "Guests won't be told."))

  # Cancelled from another tab, say: the guests were not told either.
  defp cancelled(socket, panel, told_from, :not_held),
    do:
      socket
      |> untold_again(panel, told_from)
      |> Toast.show(
        dgettext("dashboard_calendar_editing", "This update is no longer waiting to be sent.")
      )

  defp cancelled(socket, panel, _told_from, :already_sent) do
    socket
    |> assign(:panel, %{panel | guests_pending: false})
    |> Toast.show(
      dgettext("dashboard_calendar_editing", "Too late to cancel: guests have been told.")
    )
  end

  defp untold_again(socket, panel, told_from) do
    untold_from = told_from || panel.opened_with

    socket
    |> assign(:panel, %{panel | guests_pending: false, opened_with: untold_from})
    |> assign(:untold_moves, Map.put(socket.assigns.untold_moves, panel.event_id, untold_from))
  end

  @doc """
  The held update for the panel's event `id` is due (the watch `watch` the
  panel set, see `watch_hold/4`): the panel stops offering to cancel it once
  it has gone out, and looks again, later each time, while it is overdue. A
  watch the panel has since replaced, or one for another event, is ignored.
  """
  @spec recheck_pending(socket(), String.t(), integer(), pos_integer()) :: socket()
  def recheck_pending(
        %{assigns: %{panel: %{event_id: id, guests_pending: true, hold_watch: watch}}} = socket,
        id,
        watch,
        backoff
      ) do
    case panel_event(socket) do
      {:ok, event} ->
        held_until = Changes.guest_update_held_until(event)

        socket
        |> PanelState.update(&%{&1 | guests_pending: held_until != nil})
        |> forget_held_from(id, held_until)
        |> watch_hold(id, held_until, min(backoff * 2, @max_hold_backoff_ms))

      :error ->
        socket
    end
  end

  def recheck_pending(socket, _id, _watch, _backoff), do: socket

  @doc """
  Asks again once the update held for the event `id` until `held_until` is
  due (`recheck_pending/4`), so the panel's Cancel does not outlive it, and
  after `backoff` milliseconds when it is overdue already. The panel keeps
  one watch: a new one replaces the one before. The panel also keeps
  `held_until`, which Cancel names the hold by, so that only this hold
  going out counts as too late to cancel, not an earlier update. Nothing
  for no update held (`nil`).
  """
  @spec watch_hold(socket(), String.t(), DateTime.t() | nil, pos_integer()) :: socket()
  def watch_hold(socket, id, held_until, backoff \\ @hold_grace_ms)

  def watch_hold(socket, _id, nil, _backoff),
    do: PanelState.update(socket, &Map.merge(&1, %{hold_watch: nil, held_until: nil}))

  # The job's due time is Oban's, on the system clock, not `Tymeslot.Clock`.
  def watch_hold(socket, id, %DateTime{} = held_until, backoff) do
    due_in = DateTime.diff(held_until, DateTime.utc_now(), :millisecond)

    {wait, backoff} =
      if due_in > 0, do: {due_in + @hold_grace_ms, @hold_grace_ms}, else: {backoff, backoff}

    watch = System.unique_integer([:positive])

    send_update_after(
      CalendarSurface,
      [
        id: socket.assigns.id,
        action: :guests_pending_due,
        event_id: id,
        watch: watch,
        backoff: backoff
      ],
      wait
    )

    PanelState.update(socket, &Map.merge(&1, %{hold_watch: watch, held_until: held_until}))
  end

  # The panel counts from the event as it is now. While the update is held,
  # the surface remembers where it counted from before (`held_from`, by event
  # id), so a Cancel leaves the changes untold again, also in a panel opened
  # on the event later. A second Tell while one is held joins it, and keeps
  # the first starting point.
  defp count_from_now(socket, panel, event, held?) do
    held_from =
      if held?,
        do: Map.put(socket.assigns.held_from, panel.event_id, told_from(socket, panel)),
        else: Map.delete(socket.assigns.held_from, panel.event_id)

    socket
    |> assign(:panel, %{panel | opened_with: event, guests_pending: held?})
    |> assign(:held_from, held_from)
  end

  defp told_from(socket, %{guests_pending: true} = panel),
    do: Map.get(socket.assigns.held_from, panel.event_id, panel.opened_with)

  defp told_from(_socket, panel), do: panel.opened_with

  @doc """
  Forgets where the held update for the event `id` counted from once none
  is held (`held_until` nil), so a later hold, from another tab say, is not
  taken back to a starting point that belonged to an earlier one.
  """
  @spec forget_held_from(socket(), String.t(), DateTime.t() | nil) :: socket()
  def forget_held_from(socket, _id, %DateTime{}), do: socket

  def forget_held_from(socket, id, nil),
    do: assign(socket, :held_from, Map.delete(socket.assigns.held_from, id))

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
