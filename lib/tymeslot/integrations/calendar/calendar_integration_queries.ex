defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationQueries do
  @moduledoc """
  Database queries for calendar integrations.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  @doc """
  Gets all active calendar integrations for a user.
  """
  @spec list_active_for_user(integer()) :: [CalendarIntegrationSchema.t()]
  def list_active_for_user(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id and c.is_active == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets all active calendar integrations across all users.
  Used for health checks and monitoring.
  """
  @spec list_all_active() :: list(CalendarIntegrationSchema.t())
  def list_all_active do
    CalendarIntegrationSchema
    |> where([c], c.is_active == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Streams all active calendar integrations in batches, reducing over them with
  the given accumulator. Uses `Repo.stream/2` inside a transaction to avoid
  loading all rows into memory at once.

  `fun` receives each decrypted integration and the current accumulator.
  Returns the final accumulator value.
  """
  @spec stream_all_active(pos_integer(), acc, (CalendarIntegrationSchema.t(), acc -> acc)) :: acc
        when acc: term()
  def stream_all_active(max_rows \\ 100, initial_acc, fun) when is_function(fun, 2) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          CalendarIntegrationSchema
          |> where([c], c.is_active == true)
          |> order_by([c], asc: c.id)
          |> Repo.stream(max_rows: max_rows)
          |> Enum.reduce(initial_acc, fn row, acc ->
            fun.(CalendarIntegrationSchema.decrypt_credentials(row), acc)
          end)
        end,
        timeout: :infinity
      )

    result
  end

  @doc """
  Gets all calendar integrations for a user (including inactive).
  """
  @spec list_all_for_user(integer()) :: [CalendarIntegrationSchema.t()]
  def list_all_for_user(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], desc: c.is_active, asc: c.name)
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_credentials/1)
  end

  @doc """
  Gets a single calendar integration by ID.
  WARNING: This function does not check user authorization.
  Use get_for_user/2 instead for secure access.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get(integer()) :: {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(CalendarIntegrationSchema, id) do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Gets a calendar integration by ID for a specific user.
  This is the secure version that checks user authorization.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get_for_user(integer(), integer()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_for_user(id, user_id) do
    result =
      CalendarIntegrationSchema
      |> where([c], c.id == ^id and c.user_id == ^user_id)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Gets a calendar integration by user ID and provider.
  Returns {:ok, integration} if found, {:error, :not_found} otherwise.
  """
  @spec get_by_user_and_provider(integer(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_by_user_and_provider(user_id, provider) do
    result =
      CalendarIntegrationSchema
      |> where([c], c.user_id == ^user_id and c.provider == ^provider)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Finds an active calendar integration by provider and account ID for a user.
  """
  @spec get_by_account_for_user(integer(), String.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_by_account_for_user(user_id, provider, provider_account_id)
      when is_integer(user_id) and is_binary(provider) and is_binary(provider_account_id) do
    result =
      CalendarIntegrationSchema
      |> where(
        [c],
        c.user_id == ^user_id and
          c.provider == ^provider and
          c.provider_account_id == ^provider_account_id and
          c.is_active == true
      )
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Finds any calendar integration (active or inactive) by provider and account ID for a user.
  Used to detect inactive duplicates before creating a new row.
  """
  @spec get_any_by_account_for_user(integer(), String.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_any_by_account_for_user(user_id, provider, provider_account_id)
      when is_integer(user_id) and is_binary(provider) and is_binary(provider_account_id) do
    result =
      CalendarIntegrationSchema
      |> where(
        [c],
        c.user_id == ^user_id and
          c.provider == ^provider and
          c.provider_account_id == ^provider_account_id
      )
      |> order_by([c], desc: c.is_active)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      integration -> {:ok, CalendarIntegrationSchema.decrypt_credentials(integration)}
    end
  end

  @doc """
  Creates a new calendar integration.
  """
  @spec create(map()) :: {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %CalendarIntegrationSchema{}
    |> CalendarIntegrationSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a calendar integration.
  """
  @spec update(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%CalendarIntegrationSchema{} = integration, attrs) do
    integration
    |> CalendarIntegrationSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a calendar integration.
  """
  @spec delete(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(%CalendarIntegrationSchema{} = integration) do
    Repo.delete(integration)
  end

  @doc """
  Updates the last sync timestamp and clears any error.
  """
  @spec mark_sync_success(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_sync_success(%CalendarIntegrationSchema{} = integration) do
    integration
    |> Changeset.change(%{
      last_sync_at: DateTime.utc_now(:second),
      sync_error: nil
    })
    |> Repo.update()
  end

  @doc """
  Updates the sync error message.
  """
  @spec mark_sync_error(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_sync_error(%CalendarIntegrationSchema{} = integration, error_message) do
    integration
    |> Changeset.change(%{
      sync_error: error_message
    })
    |> Repo.update()
  end

  @doc """
  Toggles the active status of an integration.

  When reactivating, checks that no other active integration exists for the same
  `(user_id, provider, provider_account_id)` to prevent a unique-constraint violation.
  """
  @spec toggle_active(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t() | :duplicate_account}
  def toggle_active(%CalendarIntegrationSchema{} = integration) do
    if integration.is_active do
      integration
      |> Changeset.change(%{is_active: false})
      |> Repo.update()
    else
      case check_reactivation_conflict(integration) do
        :ok ->
          integration
          |> Changeset.change(%{is_active: true})
          |> Repo.update()

        {:error, :duplicate_account} = err ->
          err
      end
    end
  end

  defp check_reactivation_conflict(%{provider_account_id: nil}), do: :ok

  defp check_reactivation_conflict(%{provider_account_id: ""}), do: :ok

  defp check_reactivation_conflict(integration) do
    case get_by_account_for_user(
           integration.user_id,
           integration.provider,
           integration.provider_account_id
         ) do
      {:ok, _existing} -> {:error, :duplicate_account}
      {:error, :not_found} -> :ok
    end
  end

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

  @doc """
  Updates a calendar integration - delegates to update/2.
  """
  @spec update_integration(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_integration(integration, attrs), to: __MODULE__, as: :update

  @doc """
  Counts calendar integrations for a user.
  """
  @spec count_for_user(integer()) :: non_neg_integer()
  def count_for_user(user_id) do
    CalendarIntegrationSchema
    |> where([c], c.user_id == ^user_id)
    |> select([c], count(c.id))
    |> Repo.one() || 0
  end

  @doc """
  Gets all calendar integrations (for consistency checks).
  Used by data consistency service.
  """
  @spec list_all() :: list(CalendarIntegrationSchema.t())
  def list_all do
    CalendarIntegrationSchema
    |> Repo.all()
    |> Enum.map(&CalendarIntegrationSchema.decrypt_credentials/1)
  end

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

  @doc """
  Checks whether the user already has a default booking calendar set.
  """
  @spec user_has_default_booking_calendar?(integer()) :: boolean()
  def user_has_default_booking_calendar?(user_id) do
    Repo.exists?(
      from(ci in CalendarIntegrationSchema,
        where: ci.user_id == ^user_id and not is_nil(ci.default_booking_calendar_id)
      )
    )
  end

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

  @doc "Touches the notification timestamp for the given integration and field."
  @spec touch_notification_at(CalendarIntegrationSchema.t(), atom()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def touch_notification_at(integration, field)
      when field in [:last_google_notification_at, :last_outlook_notification_at] do
    integration
    |> Changeset.change(%{field => DateTime.utc_now(:second)})
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

  @doc "Updates the sync state fields for an integration."
  @spec update_sync_state(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_sync_state(integration, attrs) when is_map(attrs) do
    integration
    |> Changeset.change(attrs)
    |> Repo.update()
  end

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
      from(m in Tymeslot.Meetings.MeetingSchema,
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
