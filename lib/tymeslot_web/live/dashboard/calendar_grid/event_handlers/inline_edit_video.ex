defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.InlineEditVideo do
  @moduledoc """
  The video-provider picker on a calendar-grid event's detail panel.

  Its own handler rather than one more field in
  `TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.InlineEdit`: choosing a
  provider is not a text edit but a room being created on someone else's
  server, and it carries two guards the other inline edits have no use for.
  """

  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  @doc """
  Applies the organiser's video choice as an edit in its own right.

  Picking a provider provisions a room and puts its link on the event;
  picking "None" takes the link off. Both go through the same guards, rate
  limit and optimistic update as every other inline edit, and both answer the
  organiser once the provider and the calendar have replied.
  """
  @spec handle_update_edit_video(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_edit_video(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with {:ok, new_id} <- parse_video_choice(params["video_integration_id"]),
             false <- already_chosen?(event, new_id),
             :ok <- EditWorkflow.assert_event_editable(socket, event),
             :ok <- assert_owns_video_integration(socket, new_id),
             :ok <- Shared.check_edit_rate_limit(socket) do
          optimistic_event = Map.put(event, :video_integration_id, new_id)

          Shared.apply_optimistic_update(socket, optimistic_event, fn s ->
            EditWorkflow.change_event_video_async(s, event, new_id)
          end)
        else
          true ->
            {:noreply, socket}

          :error ->
            {:noreply, socket}

          {:error, reason} = error when reason in [:unauthorized, :read_only, :recurring_event] ->
            Shared.flash_guard_error(socket, error)

          {:error, :rate_limited, _message} = error ->
            Shared.flash_guard_error(socket, error)
        end
    end
  end

  # "None" arrives as an empty value; anything else has to be an integration
  # id, so a malformed one is ignored rather than read as a removal.
  defp parse_video_choice(value) when value in [nil, ""], do: {:ok, nil}
  defp parse_video_choice(value), do: Shared.parse_int(value)

  # Clicking the choice the event already has is not an edit. Answered before
  # the rate limit, so idle clicks on the pressed button cannot use up the
  # organiser's edits and leave a real one refused. An event whose integration
  # is set but whose link is missing is not settled: clicking that button
  # again is how an organiser repairs a room that failed to be created.
  defp already_chosen?(%{video_integration_id: nil, video_link: nil}, nil), do: true

  defp already_chosen?(%{video_integration_id: id, video_link: link}, id)
       when is_integer(id) and is_binary(link),
       do: true

  defp already_chosen?(_event, _new_id), do: false

  # The picker only ever offers the organiser's own active integrations, so
  # anything else is a forged value rather than a choice.
  defp assert_owns_video_integration(_socket, nil), do: :ok

  defp assert_owns_video_integration(socket, video_integration_id) do
    if Enum.any?(socket.assigns.video_integrations, &(&1.id == video_integration_id)),
      do: :ok,
      else: {:error, :unauthorized}
  end
end
