defmodule Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour do
  @moduledoc """
  Behaviour for Outlook Calendar API client.
  """

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema

  @type api_error ::
          {:error,
           :unauthorized | :not_found | :rate_limited | :network_error | :authentication_error,
           String.t()}

  @callback list_calendars(CalendarIntegrationSchema.t()) ::
              {:ok, [map()]} | api_error()
  @callback list_events(CalendarIntegrationSchema.t(), String.t(), DateTime.t(), DateTime.t()) ::
              {:ok, [map()]} | api_error()
  @callback list_primary_events(CalendarIntegrationSchema.t(), DateTime.t(), DateTime.t()) ::
              {:ok, [map()]} | api_error()
  @callback create_event(CalendarIntegrationSchema.t(), map()) ::
              {:ok, map()} | api_error()
  @callback create_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
              {:ok, map()} | api_error()
  @callback update_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
              {:ok, map()} | api_error()
  @callback update_event(CalendarIntegrationSchema.t(), String.t(), String.t(), map()) ::
              {:ok, map()} | api_error()
  @callback delete_event(CalendarIntegrationSchema.t(), String.t()) ::
              :ok | api_error()
  @callback delete_event(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
              :ok | api_error()
  @callback refresh_token(CalendarIntegrationSchema.t()) ::
              {:ok, {String.t(), String.t(), DateTime.t()}} | api_error()
  @callback token_valid?(CalendarIntegrationSchema.t()) :: boolean()
end
