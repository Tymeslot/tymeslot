defmodule Tymeslot.Integrations.Calendar.CalendarBehaviour do
  @moduledoc """
  Behaviour for calendar operations to enable testing with mocks.
  """

  @callback list_events_in_range(DateTime.t(), DateTime.t()) :: {:ok, list()} | {:error, any()}
  @callback get_events_for_range_fresh(pos_integer(), Date.t(), Date.t()) ::
              {:ok, list()} | {:error, any()}
  @callback create_event(map()) :: {:ok, any()} | {:error, any()}
  @callback update_event(binary(), map()) :: {:ok, any()} | {:error, any()}
  @callback delete_event(binary()) :: {:ok, any()} | {:error, any()}
end
