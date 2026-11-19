defmodule TymeslotWeb.Dashboard.Calendar.PanelEvents do
  @moduledoc """
  Every event the side panel sends, `panel:<name>`, handled on the
  calendar surface: `CalendarSurface` has one clause for them and passes the
  name here. Each one reads the panel's event from the surface
  (`PanelState.current_event/1`), so an event arriving with no panel open
  changes nothing, and parameters are client input, matched before use.
  Moving to another calendar, video, guests and the new-event form act
  through modules of their own (`Transfer`, `PanelVideo`, `PanelGuests`,
  `PanelNew`).
  """

  alias Tymeslot.CalendarGrid.EditGuard
  alias TymeslotWeb.Dashboard.Calendar.PanelColour
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.PanelFields
  alias TymeslotWeb.Dashboard.Calendar.PanelGuests
  alias TymeslotWeb.Dashboard.Calendar.PanelMeetingReminders
  alias TymeslotWeb.Dashboard.Calendar.PanelNew
  alias TymeslotWeb.Dashboard.Calendar.PanelNewDiscard
  alias TymeslotWeb.Dashboard.Calendar.PanelRepeat
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.PanelTiming
  alias TymeslotWeb.Dashboard.Calendar.PanelVideo
  alias TymeslotWeb.Dashboard.Calendar.Transfer

  # The text fields, by the event each sends (see `PanelFields.text_change/2`).
  @text_fields ~w(title location notes)

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Handles the panel event `name` with its `params`."
  @spec handle(String.t(), map(), socket()) :: socket()
  # Closing while a text field has focus: the hook sends the field and its
  # value, since the field's own blur never reaches the server once the
  # panel is gone. It is saved as that blur would save it, then the panel
  # closes, unless the value was refused or the series question is now on
  # screen, either of which keeps it open.
  def handle("close", %{"field" => field, "value" => value}, socket)
      when field in @text_fields and is_binary(value) do
    socket = socket |> clear_failure() |> then(&handle(field, %{"value" => value}, &1))

    case socket.assigns do
      %{panel: %{errors: %{^field => _message}}} -> socket
      %{series_prompt: %{kind: :panel}} -> socket
      %{panel: %{status: {:failed, _reason}}} -> socket
      _saved_or_unchanged -> PanelState.close(socket)
    end
  end

  # A New event draft with guests asks first (`PanelNewDiscard`).
  def handle("close", _params, %{assigns: %{panel: %{mode: :new}}} = socket),
    do: PanelNewDiscard.cancel(socket)

  def handle("close", _params, socket), do: PanelState.close(socket)

  # The New event form (see `PanelNew`).
  def handle("draft_change", params, socket), do: PanelNew.change(socket, params)
  def handle("draft_submit", params, socket), do: PanelNew.submit(socket, params)

  def handle("draft_drop_guest", %{"email" => email}, socket),
    do: PanelNew.drop_guest(socket, email)

  def handle("draft_add_reminder", _params, socket), do: PanelNew.add_reminder(socket)

  def handle("draft_drop_reminder", %{"index" => index}, socket),
    do: PanelNew.drop_reminder(socket, index)

  def handle("draft_cancel", _params, socket), do: PanelNewDiscard.cancel(socket)
  def handle("draft_discard_confirm", _params, socket), do: PanelNewDiscard.discard(socket)
  def handle("draft_discard_cancel", _params, socket), do: PanelNewDiscard.keep(socket)

  # The meeting's reminder picker (see `PanelMeetingReminders`).
  def handle("meeting_" <> _picker_event = name, params, socket),
    do: PanelMeetingReminders.event(socket, name, params)

  def handle("duplicate", _params, socket), do: PanelNew.duplicate(socket)

  # A swatch of the event's colour (see `PanelColour`).
  def handle("colour", %{"colour" => colour}, socket), do: PanelColour.set(socket, colour)
  def handle("delete", _params, socket), do: PanelNew.delete(socket)

  # A New event panel has no event: nothing else it could send applies.
  def handle(_name, _params, %{assigns: %{panel: %{mode: :new}}} = socket), do: socket

  def handle(field, %{"value" => value}, socket)
      when field in @text_fields and is_binary(value) do
    case {PanelState.current_event(socket.assigns), PanelFields.text_change(field, value)} do
      {nil, _change} -> socket
      {_event, {:ok, changes}} -> socket |> PanelState.put_error(field, nil) |> write(changes)
      {_event, {:error, message}} -> PanelState.put_error(socket, field, message)
    end
  end

  # Free or busy is not the organiser's to change on a booking or a booking's
  # calendar copy (the panel does not draw the switch for them either).
  def handle("free", %{"value" => choice}, socket) when choice in ["busy", "free"] do
    with %{} = event <- PanelState.current_event(socket.assigns),
         true <- EditGuard.free_busy_editable?(socket.assigns.integrations, event) do
      write(socket, %{transparency: PanelFields.transparency(choice)})
    else
      _no_panel_or_not_changeable -> socket
    end
  end

  def handle("reminder", %{"reminder" => choice}, socket) when is_binary(choice) do
    with %{} = event <- PanelState.current_event(socket.assigns),
         {:ok, reminders} <- PanelFields.reminders(Map.get(event, :reminders) || [], choice) do
      write(socket, %{reminders: reminders})
    else
      _no_panel_or_not_offered -> socket
    end
  end

  # Timing is changed only on an event whose timing can change: not a
  # booking, not a booking's calendar copy (the fields are disabled there,
  # but parameters are client input).
  def handle("timing", params, socket) do
    case movable_event(socket) do
      nil ->
        socket

      event ->
        case PanelTiming.change(event, params, socket.assigns.timezone) do
          {:ok, changes, opts} ->
            socket |> PanelState.put_error("timing", nil) |> write(changes, opts)

          :unchanged ->
            PanelState.put_error(socket, "timing", nil)

          {:error, message} ->
            PanelState.put_error(socket, "timing", message)
        end
    end
  end

  def handle("all_day", _params, socket) do
    case movable_event(socket) do
      nil ->
        socket

      event ->
        case PanelTiming.toggle_all_day(event, socket.assigns.timezone) do
          {:ok, changes, opts} ->
            socket |> PanelState.put_error("timing", nil) |> write(changes, opts)

          {:error, message} ->
            PanelState.put_error(socket, "timing", message)
        end
    end
  end

  def handle("repeat", %{"preset" => "custom"}, socket),
    do: put_repeat(socket, custom_open: true)

  def handle("repeat", %{"preset" => preset}, socket) when is_binary(preset) do
    if PanelRepeat.preset?(preset),
      do: change_preset(socket, preset),
      else: socket
  end

  def handle("repeat_toggle", _params, %{assigns: %{panel: %{repeat: repeat}}} = socket),
    do: put_repeat(socket, custom_open: !repeat.custom_open)

  def handle("repeat_custom", params, socket) do
    case PanelState.current_event(socket.assigns) do
      nil ->
        socket

      event ->
        put_repeat(socket, draft: PanelRepeat.stage(event, params, socket.assigns.timezone))
    end
  end

  def handle(
        "repeat_save",
        _params,
        %{assigns: %{panel: %{repeat: %{draft: %{notice: nil} = draft}}}} = socket
      ),
      do: socket |> put_repeat(draft: nil) |> PanelEdits.repeat({:custom, draft.params})

  def handle("repeat_discard", _params, socket), do: put_repeat(socket, draft: nil)

  # Moving the event to another calendar (see `Transfer`, which checks the
  # key against the calendars the select offered).
  def handle("transfer", %{"calendar" => key}, socket) when is_binary(key),
    do: Transfer.request(socket, key)

  def handle("confirm_series_move", _params, socket), do: Transfer.confirm_series(socket)
  def handle("cancel_series_move", _params, socket), do: Transfer.cancel_series(socket)

  def handle("video", %{"video_integration_id" => raw}, socket) when is_binary(raw),
    do: PanelVideo.change(socket, raw)

  def handle("guest_invite", %{"email" => email}, socket), do: PanelGuests.invite(socket, email)
  def handle("guest_input", _params, socket), do: PanelGuests.typed(socket)

  def handle("guest_remove", %{"email" => email}, socket),
    do: PanelGuests.request_remove(socket, email)

  def handle("guest_remove_confirm", _params, socket), do: PanelGuests.confirm_remove(socket)
  def handle("guest_remove_cancel", _params, socket), do: PanelGuests.cancel_remove(socket)
  def handle("tell_guests", _params, socket), do: PanelGuests.tell(socket)
  def handle("cancel_guest_update", _params, socket), do: PanelGuests.cancel_pending(socket)

  def handle(_name, _params, socket), do: socket

  # An older failure must not read as this attempt's refusal.
  defp clear_failure(socket),
    do:
      PanelState.update(
        socket,
        &if(match?({:failed, _}, &1.status), do: %{&1 | status: :idle}, else: &1)
      )

  # Writes to the panel's own event; with no panel open, nothing.
  defp write(socket, changes, opts \\ [])

  defp write(%{assigns: %{panel: %{event_id: id}}} = socket, changes, opts),
    do: PanelEdits.write(socket, id, changes, opts)

  defp write(socket, _changes, _opts), do: socket

  defp movable_event(socket) do
    event = PanelState.current_event(socket.assigns)
    if event && EditGuard.movable?(socket.assigns.integrations, event), do: event
  end

  # The select shows what the client chose. When the event's rule is the
  # same afterwards (refused, or waiting on the series question), the select
  # is drawn again so it shows the server's value.
  defp change_preset(socket, preset) do
    before = PanelState.current_event(socket.assigns)

    socket =
      socket
      |> put_repeat(custom_open: false, draft: nil)
      |> PanelEdits.repeat({:preset, preset})

    if rule(PanelState.current_event(socket.assigns)) == rule(before),
      do:
        PanelState.update(
          socket,
          &%{&1 | repeat: Map.update!(&1.repeat, :version, fn v -> v + 1 end)}
        ),
      else: socket
  end

  defp rule(nil), do: nil
  defp rule(event), do: Map.get(event, :recurrence_rule)

  defp put_repeat(socket, values),
    do: PanelState.update(socket, &%{&1 | repeat: Map.merge(&1.repeat, Map.new(values))})
end
