defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries do
  @moduledoc """
  Database queries for webhook/subscription lifecycle management on calendar integrations.

  Covers Google push-channel and Microsoft Graph subscription look-ups,
  expiry/silence detection, token expiry queries, delta-link persistence,
  and the advisory lock used during webhook processing.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  # ---------------------------------------------------------------------------
  # Look-ups by webhook/subscription ID
  # ---------------------------------------------------------------------------

  @doc """
  Finds an integration by its Google webhook channel ID.

  Intentionally matches inactive integrations to handle in-flight notifications gracefully.
  Returns `{:ok, integration}` with decrypted OAuth tokens if found,
  `{:error, :not_found}` otherwise.
  """
  @spec get_by_google_channel_id(String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_by_google_channel_id(channel_id) do
    result =
      CalendarIntegrationSchema
      |> where([c], c.google_channel_id == ^channel_id)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_oauth_tokens(integration)}
    end
  end

  @doc """
  Finds an integration by its Microsoft Graph subscription ID.

  Intentionally matches inactive integrations to handle in-flight notifications gracefully.
  Returns `{:ok, integration}` with decrypted OAuth tokens if found,
  `{:error, :not_found}` otherwise.
  """
  @spec get_by_graph_subscription_id(String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_by_graph_subscription_id(subscription_id) do
    result =
      CalendarIntegrationSchema
      |> where([c], c.graph_subscription_id == ^subscription_id)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_oauth_tokens(integration)}
    end
  end

  @doc """
  Fetches all integrations matching the given Graph subscription IDs in a single query.
  Returns a list of integrations with decrypted OAuth tokens.
  """
  @spec get_by_graph_subscription_ids([String.t()]) :: [CalendarIntegrationSchema.t()]
  def get_by_graph_subscription_ids([]), do: []

  def get_by_graph_subscription_ids(subscription_ids) do
    CalendarIntegrationSchema
    |> where([c], c.graph_subscription_id in ^subscription_ids)
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_oauth_tokens/1)
  end

  # ---------------------------------------------------------------------------
  # Expiring webhooks / subscriptions
  # ---------------------------------------------------------------------------

  @doc """
  Lists active Google integrations whose webhook channel expires within `hours_ahead` hours.

  Only integrations that have an active channel (non-nil `google_channel_id`) are returned.
  Results are ordered soonest-expiring first.
  """
  @spec list_expiring_google_channels(non_neg_integer()) :: [CalendarIntegrationSchema.t()]
  def list_expiring_google_channels(hours_ahead \\ 48) do
    list_expiring_webhook_integrations(
      "google",
      :google_channel_id,
      :google_channel_expires_at,
      hours_ahead
    )
  end

  @doc """
  Lists active Outlook integrations whose Graph subscription expires within `hours_ahead` hours.

  Only integrations that have an active subscription (non-nil `graph_subscription_id`) are returned.
  Results are ordered soonest-expiring first.
  """
  @spec list_expiring_outlook_subscriptions(non_neg_integer()) :: [CalendarIntegrationSchema.t()]
  def list_expiring_outlook_subscriptions(hours_ahead \\ 48) do
    list_expiring_webhook_integrations(
      "outlook",
      :graph_subscription_id,
      :graph_subscription_expires_at,
      hours_ahead
    )
  end

  # ---------------------------------------------------------------------------
  # Silent webhooks / subscriptions
  # ---------------------------------------------------------------------------

  @doc """
  Returns active Google integrations where the channel has not sent a notification
  since `cutoff_dt` (or never) AND the channel is not expired AND there is at least
  one confirmed meeting linked to the integration since `meeting_since_dt`.
  """
  @spec list_silent_google_channels(DateTime.t(), DateTime.t()) :: [CalendarIntegrationSchema.t()]
  def list_silent_google_channels(cutoff_dt, meeting_since_dt) do
    list_silent_webhook_integrations(
      "google",
      :google_channel_id,
      :google_channel_expires_at,
      :last_google_notification_at,
      cutoff_dt,
      meeting_since_dt
    )
  end

  @doc """
  Returns active Outlook integrations where the subscription has not sent a notification
  since `cutoff_dt` (or never) AND the subscription is not expired AND there is at least
  one confirmed meeting linked to the integration since `meeting_since_dt`.
  """
  @spec list_silent_outlook_subscriptions(DateTime.t(), DateTime.t()) :: [
          CalendarIntegrationSchema.t()
        ]
  def list_silent_outlook_subscriptions(cutoff_dt, meeting_since_dt) do
    list_silent_webhook_integrations(
      "outlook",
      :graph_subscription_id,
      :graph_subscription_expires_at,
      :last_outlook_notification_at,
      cutoff_dt,
      meeting_since_dt
    )
  end

  # ---------------------------------------------------------------------------
  # Expiring tokens
  # ---------------------------------------------------------------------------

  @doc """
  Lists Google Calendar integrations with tokens expiring before the given threshold.
  """
  @spec list_expiring_google_tokens(DateTime.t()) :: [CalendarIntegrationSchema.t()]
  def list_expiring_google_tokens(threshold_datetime) do
    CalendarIntegrationSchema
    |> where([c], c.provider == "google")
    |> where([c], c.is_active == true)
    |> where([c], c.token_expires_at < ^threshold_datetime)
    |> where([c], not is_nil(c.refresh_token_encrypted))
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_oauth_tokens/1)
  end

  @doc """
  Lists Outlook Calendar integrations with tokens expiring before the given threshold.
  """
  @spec list_expiring_outlook_tokens(DateTime.t()) :: [CalendarIntegrationSchema.t()]
  def list_expiring_outlook_tokens(threshold_datetime) do
    CalendarIntegrationSchema
    |> where([c], c.provider == "outlook")
    |> where([c], c.is_active == true)
    |> where([c], c.token_expires_at < ^threshold_datetime)
    |> where([c], not is_nil(c.refresh_token_encrypted))
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_oauth_tokens/1)
  end

  # ---------------------------------------------------------------------------
  # Webhook state mutations
  # ---------------------------------------------------------------------------

  @doc "Persists Google push channel fields and touches last_external_sync_at."
  @spec update_push_channel(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_push_channel(integration, attrs) do
    integration
    |> Changeset.change(Map.put(attrs, :last_external_sync_at, DateTime.utc_now(:second)))
    |> Repo.update()
  end

  @doc "Persists Microsoft Graph subscription fields and touches last_external_sync_at."
  @spec update_graph_subscription(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_graph_subscription(integration, attrs) do
    integration
    |> Changeset.change(Map.put(attrs, :last_external_sync_at, DateTime.utc_now(:second)))
    |> Repo.update()
  end

  @doc "Updates the delta link and last_external_sync_at for an integration."
  @spec update_delta_link(CalendarIntegrationSchema.t(), String.t() | nil) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_delta_link(integration, delta_link) do
    integration
    |> Changeset.change(%{
      graph_delta_link: delta_link,
      last_external_sync_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  @doc "Touches the notification timestamp for the given integration and field."
  @spec touch_notification_at(CalendarIntegrationSchema.t(), atom()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def touch_notification_at(integration, field)
      when field in [:last_google_notification_at, :last_outlook_notification_at] do
    integration
    |> Changeset.change(%{field => DateTime.utc_now(:second)})
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Advisory locking
  # ---------------------------------------------------------------------------

  @doc """
  Locks the user's profile row and all calendar integration rows for that user.
  Used to coordinate primary rebalance operations without race conditions.
  """
  @spec lock_user_profile_and_integrations(integer()) :: :ok
  def lock_user_profile_and_integrations(user_id) do
    _locked_profile =
      Repo.one(
        from(p in ProfileSchema,
          where: p.user_id == ^user_id,
          lock: "FOR UPDATE"
        )
      )

    _locked_integration_ids =
      Repo.all(
        from(ci in CalendarIntegrationSchema,
          where: ci.user_id == ^user_id,
          select: ci.id,
          lock: "FOR UPDATE"
        )
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp list_expiring_webhook_integrations(provider, id_field, expires_at_field, hours_ahead) do
    threshold = DateTime.add(DateTime.utc_now(), hours_ahead, :hour)

    CalendarIntegrationSchema
    |> where([c], c.provider == ^provider)
    |> where([c], c.is_active == true)
    |> where([c], not is_nil(field(c, ^id_field)))
    |> where([c], field(c, ^expires_at_field) < ^threshold)
    |> order_by([c], asc: field(c, ^expires_at_field))
    |> Repo.all()
  end

  defp list_silent_webhook_integrations(
         provider,
         sub_id_field,
         expires_at_field,
         notification_at_field,
         cutoff_dt,
         meeting_since_dt
       ) do
    now = DateTime.utc_now()

    meeting_integration_ids =
      from(m in MeetingSchema,
        where: m.status == "confirmed" and m.start_time >= ^meeting_since_dt,
        where: not is_nil(m.calendar_integration_id),
        select: m.calendar_integration_id,
        distinct: true
      )

    Repo.all(
      from(i in CalendarIntegrationSchema,
        where:
          i.provider == ^provider and
            i.is_active == true and
            not is_nil(field(i, ^sub_id_field)) and
            not is_nil(field(i, ^expires_at_field)) and
            field(i, ^expires_at_field) > ^now and
            (is_nil(field(i, ^notification_at_field)) or
               field(i, ^notification_at_field) < ^cutoff_dt),
        where: i.id in subquery(meeting_integration_ids)
      )
    )
  end
end
