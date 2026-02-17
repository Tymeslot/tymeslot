defmodule Tymeslot.Utils.ContextUtils do
  @moduledoc """
  Utilities for extracting data from various contexts (maps, sockets, etc.).
  """

  @doc """
  Safely extracts a value from a context.
  The context can be:
  - A Phoenix.LiveView.Socket (checks assigns then private)
  - A map
  - nil (returns nil)
  """
  @spec get_from_context(map() | nil, any()) :: any()
  def get_from_context(nil, _key), do: nil

  def get_from_context(context, key) do
    case context do
      %{assigns: assigns} = socket ->
        # Handle Phoenix.LiveView.Socket (check assigns then private)
        case Map.get(assigns, key) do
          nil -> if Map.has_key?(socket, :private), do: Map.get(socket.private, key), else: nil
          val -> val
        end

      %{} = map ->
        Map.get(map, key)

      _other ->
        nil
    end
  end
end
