defmodule Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour do
  @moduledoc """
  Behaviour for calendar provider implementations (CalDAV, Google Calendar, Outlook, etc.).

  This defines the contract that all calendar providers must implement.
  """

  @doc """
  Creates a new client instance for the provider.
  """
  @callback new(config :: map()) :: any()

  @doc """
  Lists all events from the calendar.
  """
  @callback get_events(client :: any()) :: {:ok, list()} | {:error, any()}

  @doc """
  Lists events within a specific date range.
  """
  @callback get_events(client :: any(), start_time :: DateTime.t(), end_time :: DateTime.t()) ::
              {:ok, list()} | {:error, any()}

  @doc """
  Creates a new event in the calendar.
  """
  @callback create_event(client :: any(), event_data :: map()) :: {:ok, any()} | {:error, any()}

  @doc """
  Updates an existing event in the calendar.
  """
  @callback update_event(client :: any(), uid :: String.t(), event_data :: map()) ::
              :ok | {:ok, any()} | {:error, any()}

  @doc """
  Deletes an event from the calendar.
  """
  @callback delete_event(client :: any(), uid :: String.t()) ::
              :ok | {:ok, any()} | {:error, any()}

  @doc """
  Returns the provider type identifier.
  """
  @callback provider_type() :: atom()

  @doc """
  Returns the display name for this provider.
  """
  @callback display_name() :: String.t()

  @doc """
  Returns the configuration schema for this provider.
  """
  @callback config_schema() :: map()

  @doc """
  Validates the provider configuration.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, String.t()}
end
