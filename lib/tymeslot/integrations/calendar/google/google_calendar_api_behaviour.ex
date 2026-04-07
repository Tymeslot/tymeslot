defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour do
  @moduledoc """
  Behaviour for Google Calendar API client.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @type api_error ::
          {:error,
           :unauthorized
           | :not_found
           | :rate_limited
           | :network_error
           | :authentication_error
           | :gone, String.t()}

  @callback list_calendars(CalendarIntegrationSchema.t()) ::
              {:ok, [map()]} | api_error()
  @callback list_events(CalendarIntegrationSchema.t(), String.t(), DateTime.t(), DateTime.t()) ::
              {:ok, [map()]} | api_error()
  @callback list_primary_events(CalendarIntegrationSchema.t(), DateTime.t(), DateTime.t()) ::
              {:ok, [map()]} | api_error()
  @callback create_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
              {:ok, map()} | api_error()
  @callback update_event(CalendarIntegrationSchema.t(), String.t(), String.t(), map()) ::
              {:ok, map()} | api_error()
  @callback delete_event(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
              :ok | api_error()
  @callback refresh_token(CalendarIntegrationSchema.t()) ::
              {:ok, {String.t(), String.t(), DateTime.t()}} | api_error()
  @callback token_valid?(CalendarIntegrationSchema.t()) :: boolean()
  @callback list_events_incremental(CalendarIntegrationSchema.t()) ::
              {:ok, %{events: [map()], next_sync_token: String.t() | nil}}
              | {:error, :gone, String.t()}
              | api_error()
  @callback register_push_channel(CalendarIntegrationSchema.t()) ::
              {:ok, CalendarIntegrationSchema.t()}
              | {:error, :webhook_base_url_not_configured}
              | {:error, :circuit_open}
              | api_error()
end
