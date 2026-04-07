defmodule Tymeslot.Integrations.Calendar.Webhooks do
  @moduledoc """
  Webhook lookup and notification tracking for calendar integrations.

  Used by Google Calendar and Outlook webhook controllers to find
  integrations by their provider-specific channel/subscription IDs
  and to record notification timestamps.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @type integration :: CalendarIntegrationSchema.t()

  @doc """
  Finds an integration by its Google webhook channel ID.
  Used by the Google Calendar webhook controller.
  """
  @spec get_by_google_channel_id(String.t()) ::
          {:ok, integration()} | {:error, :not_found}
  def get_by_google_channel_id(channel_id) do
    CalendarIntegrationQueries.get_by_google_channel_id(channel_id)
  end

  @doc """
  Finds an integration by its Microsoft Graph subscription ID.
  Used by the Outlook Calendar webhook and lifecycle controllers.
  """
  @spec get_by_graph_subscription_id(String.t()) ::
          {:ok, integration()} | {:error, :not_found}
  def get_by_graph_subscription_id(subscription_id) do
    CalendarIntegrationQueries.get_by_graph_subscription_id(subscription_id)
  end

  @doc """
  Fetches all integrations matching the given Graph subscription IDs in a single query.
  Used by the Outlook webhook controller for batch notification processing.
  """
  @spec get_by_graph_subscription_ids([String.t()]) :: [integration()]
  def get_by_graph_subscription_ids(subscription_ids) do
    CalendarIntegrationQueries.get_by_graph_subscription_ids(subscription_ids)
  end

  @doc """
  Touches the notification timestamp for the given integration and field.
  Used by webhook controllers to track the last notification time.
  """
  @spec touch_notification_at(integration(), atom()) ::
          {:ok, integration()} | {:error, Ecto.Changeset.t()}
  def touch_notification_at(integration, field) when is_atom(field) do
    CalendarIntegrationQueries.touch_notification_at(integration, field)
  end
end
