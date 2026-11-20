defmodule TymeslotWeb.Dashboard.Calendar.SurfaceEventActions do
  @moduledoc """
  What the calendar surface does when the grid or the preview asks for
  something on one event or draft (`calendar:*` events): open its preview,
  edit it in the side panel, mark it busy or free, create a quick-create
  draft or take it to the panel's More options, answer the series question,
  and delete it. `CalendarSurface` routes these events here (its
  `@event_actions`); each answers as `handle_event/3` would.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.Deletion
  alias TymeslotWeb.Dashboard.Calendar.FreeBusy
  alias TymeslotWeb.Dashboard.Calendar.Manipulation
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.PanelNew
  alias TymeslotWeb.Dashboard.Calendar.PanelNewDiscard
  alias TymeslotWeb.Dashboard.Calendar.PanelState

  @type socket :: Phoenix.LiveView.Socket.t()

  # What each prompt can send; the module that acts on it parses it again.
  @timing_scopes ~w(this_only following all)
  @delete_scopes ~w(occurrence series)
  @repeat_scopes ~w(following all)

  @doc "Answers the event `event` with its `params`, as `handle_event/3` would."
  @spec handle(String.t(), map(), socket()) ::
          {:noreply, socket()} | {:reply, map(), socket()}
  # Only an event in the loaded window, which holds this organiser's events
  # alone, can be opened; anything else answers `opened: false`.
  # A New event draft with uninvited guests asks first, and opens the
  # preview once Discard is chosen (`PanelNewDiscard`).
  def handle("calendar:open", %{"id" => id}, socket) when is_binary(id) do
    if Map.has_key?(socket.assigns.events_by_id, id),
      do: open_preview(socket, id),
      else: {:reply, %{opened: false}, assign(socket, :preview, nil)}
  end

  def handle("calendar:open", _params, socket), do: {:reply, %{opened: false}, socket}

  # Opens the side panel on a loaded event: from the hook (E on a focused
  # event) or the preview's Edit button.
  def handle("calendar:edit", %{"id" => id}, socket) when is_binary(id) do
    case PanelNewDiscard.hold(socket, {:edit, id}) do
      {:held, socket} -> {:noreply, socket}
      :go -> {:noreply, PanelState.open_edit(socket, id)}
    end
  end

  def handle("calendar:edit", _params, socket), do: {:noreply, socket}

  def handle("calendar:set_free", %{"id" => id, "free" => free}, socket)
      when is_binary(id) and free in ["true", "false"],
      do: {:noreply, FreeBusy.set(socket, id, free == "true")}

  def handle("calendar:set_free", _params, socket), do: {:noreply, socket}

  # The reply tells the hook whether its draft was accepted, or which field
  # was refused and why (see `Creation`).
  def handle("calendar:create", params, socket) do
    {reply, socket} = Creation.create(socket, params)
    {:reply, reply, socket}
  end

  # Quick create's More options: the panel opens in its New event state on
  # the draft (see `PanelNew`); the hook keeps drawing it until the payload.
  # Every path replies, so the popover never waits on its timeout.
  # Leaving a New event draft with uninvited guests for another asks first;
  # after Discard the hook is told to choose More options again.
  def handle("calendar:more_options", %{"draft" => draft} = params, socket)
      when is_binary(draft) do
    case PanelNewDiscard.hold(socket, {:more_options, draft}) do
      {:held, socket} ->
        {:reply, %{opened: false}, socket}

      :go ->
        {opened, socket} = PanelNew.open(socket, params)
        {:reply, %{opened: opened}, socket}
    end
  end

  def handle("calendar:more_options", params, socket) do
    {opened, socket} = PanelNew.open(socket, params)
    {:reply, %{opened: opened}, socket}
  end

  # The scope is client input: only the scopes the open prompt offers are
  # acted on.
  def handle("calendar:choose_scope", %{"scope" => scope}, socket)
      when is_binary(scope) do
    case socket.assigns.series_prompt do
      %{kind: :timing} when scope in @timing_scopes ->
        {:noreply, Manipulation.choose_scope(socket, scope)}

      %{kind: :panel} when scope in @timing_scopes ->
        {:noreply, PanelEdits.choose_scope(socket, scope)}

      %{kind: :panel_repeat} when scope in @repeat_scopes ->
        {:noreply, PanelEdits.choose_scope(socket, scope)}

      %{kind: :delete} when scope in @delete_scopes ->
        {:noreply, Deletion.choose_scope(socket, scope)}

      _none_or_not_offered ->
        {:noreply, socket}
    end
  end

  def handle("calendar:choose_scope", _params, socket), do: {:noreply, socket}

  def handle("calendar:cancel_scope", _params, socket),
    do: {:noreply, Manipulation.cancel_scope(socket)}

  def handle("calendar:delete", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, Deletion.request(socket, id)}

  def handle("calendar:delete", _params, socket), do: {:noreply, socket}

  def handle("calendar:confirm_delete", %{"notify" => notify}, socket)
      when is_binary(notify),
      do: {:noreply, Deletion.confirm(socket, notify)}

  def handle("calendar:confirm_delete", _params, socket), do: {:noreply, socket}

  def handle("calendar:cancel_delete", _params, socket),
    do: {:noreply, Deletion.cancel(socket)}

  # Focus goes back to the event chip only for the Close button and Escape;
  # a click elsewhere (`refocus: "false"` from the click-away) keeps focus
  # where the organiser put it.
  def handle("calendar:close_preview", params, socket) do
    socket = assign(socket, :preview, nil)

    if Map.get(params, "refocus") == "false",
      do: {:noreply, socket},
      else: {:noreply, push_event(socket, "calendar:preview-closed", %{})}
  end

  defp open_preview(socket, id) do
    case PanelNewDiscard.hold(socket, {:open, id}) do
      {:held, socket} -> {:reply, %{opened: false}, socket}
      :go -> {:reply, %{opened: true}, PanelState.open_preview(socket, id)}
    end
  end
end
