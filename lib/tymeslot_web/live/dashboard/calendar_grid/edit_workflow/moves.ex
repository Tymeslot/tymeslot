defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Moves do
  @moduledoc """
  Cross-integration event moves: delete on source, create on destination.

  Each step can fail independently and the recovery differs — case A
  (delete fails) leaves local state untouched and the user can retry;
  case B (delete succeeds but create fails) has already moved the source
  server's state and needs the OfflineQueue to finish the create on the
  destination.
  """

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias Tymeslot.Utils.MapKeys

  @doc """
  Moves an event from one integration to another via delete + create.
  Runs asynchronously; sends `{:event_move_result, ...}` to the LiveView.
  """
  @spec move_event_async(Phoenix.LiveView.Socket.t(), map(), integer()) ::
          Phoenix.LiveView.Socket.t()
  @spec move_event_async(Phoenix.LiveView.Socket.t(), map(), integer(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def move_event_async(socket, event, new_integration_id, opts \\ []) do
    user_id = socket.assigns.current_user.id
    lv_pid = self()
    new_calendar_id = opts[:calendar_id]

    new_integration = Enum.find(socket.assigns.integrations, &(&1.id == new_integration_id))

    new_provider = new_integration && new_integration.provider

    new_provider_calendar_id =
      new_calendar_id ||
        (new_integration && new_integration.default_booking_calendar_id) ||
        "primary"

    # Generate the destination UID upfront so that a failed create can be
    # retried by OfflineQueue with the same identifier — both the first
    # attempt and any subsequent replay address the same event server-side.
    new_uid = ICalBuilder.generate_uid()

    event_attrs = %{
      uid: new_uid,
      summary: event.summary || "",
      start_time: event.start_at,
      end_time: event.end_at,
      description: event.description || "",
      location: event.location || "",
      all_day: event.all_day || false,
      calendar_id: new_calendar_id,
      calendar_integration_id: new_integration_id
    }

    delete_opts =
      if event.provider_event_id,
        do: [provider_event_id: event.provider_event_id],
        else: []

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      run_move_steps(%{
        lv_pid: lv_pid,
        event: event,
        user_id: user_id,
        delete_opts: delete_opts,
        event_attrs: event_attrs,
        new_uid: new_uid,
        new_integration_id: new_integration_id,
        new_provider: new_provider,
        new_provider_calendar_id: new_provider_calendar_id
      })
    end)

    socket
  end

  defp run_move_steps(ctx) do
    # Uses EventOperations directly: the 3-arity delete_event/3 with opts
    # (provider_event_id) is not exposed on the Calendar.Events public API.
    case EventOperations.delete_event(
           ctx.event.uid,
           {ctx.event.calendar_integration_id, ctx.user_id},
           ctx.delete_opts
         ) do
      :ok ->
        run_move_create_step(ctx)

      {:error, reason} ->
        # Case A: delete failed. Source event still exists. Do not tag
        # anything — the user may retry the move or abandon it.
        send(
          ctx.lv_pid,
          {:event_move_result, {:error, original_event: ctx.event, reason: reason}}
        )
    end
  end

  defp run_move_create_step(ctx) do
    case CalendarEvents.create_event(ctx.event_attrs, {ctx.new_integration_id, ctx.user_id}) do
      {:ok, created} ->
        finish_successful_move(ctx, created)

      {:error, reason} ->
        # Case B: delete succeeded, create failed. The source server no
        # longer has the event and the destination never received it.
        # Tag the destination so OfflineQueue.flush/2 retries the create
        # on the next sync cycle — CalDAV destinations only; other
        # providers will surface the failure and the user must retry.
        tag_move_create_for_offline_retry(ctx)

        send(
          ctx.lv_pid,
          {:event_move_result, {:error, original_event: ctx.event, reason: reason}}
        )
    end
  end

  defp finish_successful_move(ctx, created) do
    CalendarGrid.delete_cached_event(ctx.event.calendar_integration_id, ctx.event.uid)

    uid =
      if is_binary(created), do: created, else: MapKeys.get_binary(created, :uid) || ctx.new_uid

    timing =
      if ctx.event.all_day do
        %{start_date: ctx.event.start_date, end_date: ctx.event.end_date}
      else
        %{start_at: ctx.event.start_at, end_at: ctx.event.end_at}
      end

    CalendarGrid.cache_created_event(
      Map.merge(timing, %{
        uid: uid,
        calendar_integration_id: ctx.new_integration_id,
        provider: ctx.new_provider,
        provider_calendar_id: ctx.new_provider_calendar_id,
        summary: ctx.event.summary,
        all_day: ctx.event.all_day || false
      })
    )

    send(
      ctx.lv_pid,
      {:event_move_result, {:ok, uid: uid, integration_id: ctx.new_integration_id}}
    )
  end

  defp tag_move_create_for_offline_retry(ctx) do
    meeting = %{
      uid: ctx.new_uid,
      calendar_integration_id: ctx.new_integration_id
    }

    EventOperations.tag_for_offline_retry(meeting, :create, ctx.event_attrs)
  end
end
