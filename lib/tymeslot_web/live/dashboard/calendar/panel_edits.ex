defmodule TymeslotWeb.Dashboard.Calendar.PanelEdits do
  @moduledoc """
  Writing what is changed in the side panel, on the calendar surface.

  `write/4` takes the change a panel field made. A value the event already
  has writes nothing; the rest is checked like any other change
  (`EditGuard`) and written through `Calendar.Writes`, the surface's write
  queue, which shows it on the grid at once. Each write to one event goes on
  the undo stack as an `:edit` entry carrying what it replaced, and Ctrl Z
  takes it back through the same path (`undo/2`). The panel shows no toast
  per change, unless the caller asks for one (`toast:`): its header says
  how its writes went (`PanelStatus`).

  A member of a repeating series asks "this / following / all" once, at
  the first change, and the answer is kept in `panel.scope` for every later
  change until the panel closes. A change to several events of a series
  cannot be undone here, as on the grid.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.RecurrenceScope
  alias Tymeslot.CalendarGrid.WriteQueue
  alias TymeslotWeb.Dashboard.Calendar.PanelRepeat
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.PanelStatus
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Dashboard.Calendar.Writes
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Writes `changes` (fields `Tymeslot.CalendarGrid.EventEdit` takes) to the
  event `event_id`: a loaded event, or the panel's own when a reload has
  dropped it. `opts` go to the write (`timezone:` and the like), except
  `toast:`, a message shown in a toast once the write is sent (with Undo
  when the change can be undone). The values the event already has are
  dropped first; when nothing is left, nothing is written. A refused change
  says why in the panel's header. While the event moves to another calendar
  (`Transfer.moving?/2`) the change is refused in the header.
  """
  @spec write(socket(), String.t(), map(), keyword()) :: socket()
  def write(socket, event_id, changes, opts) do
    case target_event(socket.assigns, event_id) do
      nil ->
        socket

      event ->
        if Transfer.moving?(socket, EventPayload.id(event)),
          do: refuse_with(socket, CalendarEditMessages.moving_message()),
          else: write_event(socket, event, changes, opts)
    end
  end

  defp write_event(socket, event, changes, opts) do
    {toast, opts} = Keyword.pop(opts, :toast)
    changes = changed(event, changes)

    with true <- map_size(changes) > 0,
         :ok <- guard(socket, event, changes) do
      in_scope(socket, event, %{kind: :panel, changes: changes, opts: opts, toast: toast})
    else
      false -> socket
      refusal -> refuse(socket, refusal)
    end
  end

  @doc """
  Writes the repeat rule `spec` makes (`{:preset, key}` or `{:custom,
  fields}`, see `PanelRepeat`) to the panel's event. On a member of a series
  the rule is written to this and the following events or to all of them,
  asked unless the panel already holds one of those two; removing it from a
  series is refused without asking.
  """
  @spec repeat(socket(), PanelRepeat.spec()) :: socket()
  def repeat(socket, spec) do
    case PanelState.current_event(socket.assigns) do
      nil -> socket
      event -> repeat_event(socket, event, spec)
    end
  end

  # `%{recurrence_rule: nil}` only picks the guard: a rule change is no
  # change of timing.
  defp repeat_event(socket, event, spec) do
    case guard(socket, event, %{recurrence_rule: nil}) do
      :ok -> repeat_if_written(socket, event, spec)
      refusal -> refuse(socket, refusal)
    end
  end

  # The select is disabled for a calendar that takes no repeat rules, but
  # the event arrives from the client all the same.
  defp repeat_if_written(socket, event, spec) do
    if Changes.repeatable_provider?(Map.get(event, :provider)),
      do: repeat_in_scope(socket, event, spec),
      else: refuse_with(socket, CalendarEditMessages.repeat_refusal(:not_supported))
  end

  defp repeat_in_scope(socket, event, spec) do
    case {Changes.edit_scopes(event), spec} do
      {{:ok, :series}, {:preset, "none"}} ->
        refuse_with(socket, CalendarEditMessages.repeat_refusal(:removal))

      _single_or_scoped ->
        in_scope(socket, event, %{kind: :panel_repeat, spec: spec})
    end
  end

  @doc "Sets the panel's header line (see `PanelStatus`)."
  @spec put_status(socket(), PanelStatus.t()) :: socket()
  def put_status(socket, status), do: PanelState.update(socket, &%{&1 | status: status})

  @doc """
  Writes the change waiting on the panel's series question in the scope
  chosen, and keeps the scope for the panel's later changes.
  """
  @spec choose_scope(socket(), String.t()) :: socket()
  def choose_scope(%{assigns: %{series_prompt: prompt}} = socket, scope) do
    with true <- PanelState.panel_prompt?(prompt),
         {:ok, scope} <- RecurrenceScope.parse(scope) do
      socket
      |> assign(:series_prompt, nil)
      |> keep_scope(prompt.kind, scope)
      |> run(prompt.event, prompt, scope)
    else
      _no_panel_question_or_scope -> assign(socket, :series_prompt, nil)
    end
  end

  # The answer to a field change's question holds for the panel's later
  # changes. The answer to a rule change's question is for that change
  # alone: a later field edit asks its own, rather than reach several events
  # unasked.
  defp keep_scope(socket, :panel_repeat, _scope), do: socket

  defp keep_scope(socket, _kind, scope), do: PanelState.update(socket, &%{&1 | scope: scope})

  @doc "After the write `ref` answered `outcome`: the panel's header follows its own writes."
  @spec settled(socket(), WriteQueue.ref(), WriteQueue.outcome()) :: socket()
  def settled(%{assigns: %{panel: %{} = panel}} = socket, ref, outcome) do
    account = account_name(socket.assigns, panel)
    assign(socket, :panel, PanelStatus.settled(panel, ref, outcome, account))
  end

  def settled(socket, _ref, _outcome), do: socket

  @doc """
  Undoes an `:edit` entry: writes the values the change replaced, in the
  way the change was written (`entry.opts`), while the event still has the
  values the change gave it; an event changed or synced since is not put
  back over its newer version.
  """
  @spec undo(socket(), map()) :: socket()
  def undo(socket, entry) do
    with {:ok, event} <- Map.fetch(socket.assigns.events_by_id, entry.id),
         true <- unchanged_since?(event, entry.after),
         :ok <- guard(socket, event, entry.before) do
      {socket, ref} =
        Writes.update(socket, event, Map.merge(event, entry.before), entry.before, entry.opts)

      socket
      |> assign(:undoing, Map.put(socket.assigns.undoing, ref, entry))
      |> track(entry.id, ref, Map.merge(event, entry.before))
      |> Toast.show(dgettext("dashboard_calendar_editing", "Change undone"), key: entry.key)
    else
      {:error, :rate_limited, _message} = refusal ->
        socket |> assign(:undo, UndoStack.push(socket.assigns.undo, entry)) |> flash(refusal)

      {:error, _reason} = refusal ->
        flash(socket, refusal)

      _gone_or_changed ->
        Toast.show(
          socket,
          dgettext("dashboard_calendar_editing", "That change can't be undone any more.")
        )
    end
  end

  defp target_event(assigns, event_id) do
    case PanelState.fetch_event(assigns, event_id) do
      {:ok, event} -> event
      :error -> nil
    end
  end

  defp in_scope(socket, event, pending) do
    case Changes.edit_scopes(event) do
      {:ok, :single} -> run(socket, event, pending, nil)
      {:ok, :this_only} -> run(socket, event, pending, :this_only)
      {:ok, :series} -> series_scope(socket, event, pending)
    end
  end

  # Asked once; the answer holds until the panel closes. A rule change is
  # written to this and the following events or to all of them, so a panel
  # holding "This event" asks again.
  defp series_scope(socket, event, pending) do
    case {socket.assigns.panel, pending.kind} do
      {%{scope: scope}, :panel_repeat} when scope in [:following, :all] ->
        run(socket, event, pending, scope)

      {_panel, :panel_repeat} ->
        ask(socket, event, pending)

      {%{scope: scope}, _kind} when scope != nil ->
        run(socket, event, pending, scope)

      _no_answer_yet ->
        ask(socket, event, pending)
    end
  end

  defp ask(socket, event, pending) do
    assign(
      socket,
      :series_prompt,
      Map.merge(pending, %{event: event, title: EventPayload.title(event)})
    )
  end

  # A write to several events of a series waits for no other write of that
  # series: one still running is refused, as on the grid.
  defp run(socket, event, %{kind: :panel} = pending, scope) do
    if scope in [:following, :all] and Writes.series_busy?(socket, event),
      do: refuse_with(socket, CalendarEditMessages.series_saving_message()),
      else: write_now(socket, event, pending, scope)
  end

  defp run(socket, event, %{kind: :panel_repeat, spec: spec}, scope) do
    case PanelRepeat.rule_for(spec, event, scope, socket.assigns.timezone) do
      {:ok, rule, opts} ->
        run(socket, event, %{kind: :panel, changes: %{recurrence_rule: rule}, opts: opts}, scope)

      :unchanged ->
        socket

      {:error, message} ->
        refuse_with(socket, message)
    end
  end

  defp write_now(socket, event, %{changes: changes, opts: opts} = pending, scope) do
    opts = opts ++ scope_opts(scope)
    optimistic = Map.merge(event, changes)
    {socket, ref} = Writes.update(socket, event, optimistic, changes, opts)
    # A rule given to a one-off cannot be taken back: Outlook's PATCH drops a
    # nil rule, so the entry would say "undone" and change nothing.
    undoable? = scope in [nil, :this_only] and not Map.has_key?(changes, :recurrence_rule)

    # `ref` names the write, so a failure of it forgets this entry alone
    # (`Manipulation.forget/2`).
    entry = %{
      kind: :edit,
      key: WriteQueue.key(event),
      ref: ref,
      id: EventPayload.id(event),
      before: Map.take(event, Map.keys(changes)),
      after: changes,
      scope: scope,
      opts: opts
    }

    socket
    |> remember(undoable?, entry)
    |> track(entry.id, ref, optimistic)
    |> maybe_toast(Map.get(pending, :toast), undoable?, entry.key)
  end

  defp remember(socket, false, _entry), do: socket

  defp remember(socket, true, entry),
    do: assign(socket, :undo, UndoStack.push(socket.assigns.undo, entry))

  defp maybe_toast(socket, nil, _undoable?, _key), do: socket

  defp maybe_toast(socket, message, undoable?, key),
    do: Toast.show(socket, message, undo: undoable?, key: key)

  # A write to the panel's own event shows in its header.
  defp track(%{assigns: %{panel: %{event_id: id}}} = socket, id, ref, event),
    do: PanelState.update(socket, &PanelStatus.started(%{&1 | event: event}, ref))

  defp track(socket, _id, _ref, _event), do: socket

  defp guard(socket, event, changes) do
    %{current_user: user, integrations: integrations} = socket.assigns

    if EditGuard.timing_change?(changes),
      do: EditGuard.check_timing(user.id, integrations, event),
      else: EditGuard.check(user.id, integrations, event)
  end

  # A refusal shows in the panel's header; with no panel open (a change made
  # from the preview) it is flashed instead, or it would be silent.
  defp refuse(%{assigns: %{panel: %{}}} = socket, refusal),
    do: refuse_with(socket, refusal |> CalendarEditMessages.refusal() |> elem(1))

  defp refuse(socket, refusal), do: flash(socket, refusal)

  defp refuse_with(%{assigns: %{panel: %{}}} = socket, message),
    do: PanelState.update(socket, &PanelStatus.refused(&1, message))

  defp refuse_with(socket, message) do
    send(self(), {:flash, {:warning, message}})
    socket
  end

  defp flash(socket, refusal) do
    send(self(), {:flash, CalendarEditMessages.refusal(refusal)})
    socket
  end

  defp scope_opts(nil), do: []
  defp scope_opts(scope), do: [recurrence_scope: scope]

  defp changed(event, changes),
    do: Map.reject(changes, fn {key, value} -> same_value?(Map.get(event, key), value) end)

  defp unchanged_since?(event, values),
    do: Enum.all?(values, fn {key, value} -> same_value?(Map.get(event, key), value) end)

  # An empty text field and a missing value are the same; instants compare
  # by when they are, whatever their precision.
  defp same_value?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_value?(a, b) when a in [nil, ""] and b in [nil, ""], do: true
  defp same_value?(a, b), do: a == b

  defp account_name(assigns, panel) do
    id = Map.get(panel.event || %{}, :calendar_integration_id)

    case Enum.find(assigns.integrations, &(&1.id == id)) do
      %{name: name} -> name
      nil -> dgettext("dashboard_calendar_editing", "your calendar")
    end
  end
end
