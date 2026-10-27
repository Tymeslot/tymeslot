defmodule Tymeslot.Integrations.Calendar.Providers.OAuthProvider do
  @moduledoc """
  What an OAuth calendar provider (Google, Outlook) supplies to
  `Tymeslot.Integrations.Calendar.Providers.OAuthBase`, which builds the rest
  of its `Tymeslot.Integrations.Calendar.Provider` implementation from these.
  """

  @callback validate_oauth_scope(config :: map()) :: :ok | {:error, String.t()}
  @callback convert_event(event :: map()) :: map()
  @callback get_calendar_api_module() :: module()
  @callback call_list_events(
              integration :: term(),
              start_time :: DateTime.t(),
              end_time :: DateTime.t()
            ) :: term()
  @callback call_create_event(integration :: term(), event_attrs :: map()) :: term()
  @callback call_update_event(
              integration :: term(),
              event_id :: String.t(),
              event_attrs :: map()
            ) :: term()
  @callback call_delete_event(
              integration :: term(),
              event_id :: String.t(),
              opts :: keyword()
            ) :: term()
end
