defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateRecurrence do
  @moduledoc """
  The repeat editor in the create form: the fields it sends are kept
  (`:recurrence_params`) and composed into the rule the new event is saved
  with.

  A repeat pattern is anchored to the event's start (`Pattern`), and the
  start date and all-day flag can still change after a pattern is picked,
  so the rule is composed again from the editor's fields whenever they do
  (`recompose/2`). A position the new date is not (it is no longer the
  second Tuesday) becomes the nearest one it is, or its own day, which the
  editor then shows. `CreateExecution` still refits the rule's end to the
  event it saves.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  @doc "Keeps the editor's fields and composes the new event's rule from them."
  @spec handle_update_create_recurrence(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_create_recurrence(params, socket) do
    case socket.assigns.creating_event do
      nil ->
        {:noreply, socket}

      creating ->
        updated =
          creating
          |> Map.put(:recurrence_params, params)
          |> recompose(socket.assigns.user_timezone)

        {:noreply, assign(socket, :creating_event, updated)}
    end
  end

  @doc "Composes `creating`'s rule again from its kept fields, for its current start."
  @spec recompose(map(), String.t()) :: map()
  def recompose(%{recurrence_params: params} = creating, timezone) do
    context = %{
      timezone: timezone,
      all_day: Map.get(creating, :all_day, false),
      start_date: parse_date(creating.date),
      # An end before the start is reported when the event is saved.
      check_until: false
    }

    Map.put(creating, :recurrence_rule, Shared.compose_recurrence_rule(params, context))
  end

  def recompose(creating, _timezone), do: creating

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil
end
