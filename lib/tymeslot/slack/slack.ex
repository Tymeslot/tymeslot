defmodule Tymeslot.Slack do
  @moduledoc """
  Context module for Slack integration management and delivery.

  Public boundary for the Slack feature — controllers, LiveViews, and workers
  must call into this module rather than reaching into queries, schemas or the
  HTTP client directly.
  """

  @behaviour Tymeslot.Notifications.Channel
  @behaviour Tymeslot.Security.EncryptedStorage

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.Channel
  alias Tymeslot.Notifications.EventOptions

  alias Tymeslot.Slack.{
    AccountCleanup,
    API,
    ErrorMessages,
    Install,
    MessageBuilder,
    OAuth,
    SlackIntegrationSchema,
    SlackQueries
  }

  alias Tymeslot.Workers.SlackWorker

  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage,
    do:
      {SlackIntegrationSchema.__schema__(:source),
       SlackIntegrationSchema.encrypted_credential_fields()}

  # ============================================================================
  # CRUD Operations
  # ============================================================================

  @spec list_integrations(integer()) :: [SlackIntegrationSchema.t()]
  def list_integrations(user_id) do
    SlackQueries.list_integrations(user_id)
  end

  @spec get_integration(integer(), integer()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id, user_id) do
    SlackQueries.get_integration(id, user_id)
  end

  @doc """
  Revokes the bot token of every Slack workspace the user connected, for an
  account being deleted (see `Tymeslot.Slack.AccountCleanup`).
  """
  @spec revoke_tokens_for_user(integer()) :: :ok
  defdelegate revoke_tokens_for_user(user_id), to: AccountCleanup, as: :run

  @spec create_integration(integer(), map()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error,
             Ecto.Changeset.t()
             | :insufficient_plan
             | :feature_access_checker_failed
             | :feature_disabled}
  def create_integration(user_id, attrs) do
    if slack_enabled?() do
      with :ok <- Features.check_access(user_id, :automations_allowed) do
        attrs
        |> Map.put(:user_id, user_id)
        |> SlackQueries.create_integration()
      end
    else
      {:error, :feature_disabled}
    end
  end

  @doc """
  Creates an integration that posts through a pasted Incoming Webhook URL.
  """
  @spec create_webhook_integration(integer(), map()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error,
             Ecto.Changeset.t()
             | :insufficient_plan
             | :feature_access_checker_failed
             | :feature_disabled}
  def create_webhook_integration(user_id, attrs) do
    create_integration(user_id, Map.put(attrs, :app_mode, :webhook_url))
  end

  @spec update_integration(SlackIntegrationSchema.t(), map()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def update_integration(integration, attrs) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed) do
      SlackQueries.update_integration(integration, attrs)
    end
  end

  @spec delete_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_integration(integration) do
    SlackQueries.delete_integration(integration)
  end

  @spec toggle_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error,
             Ecto.Changeset.t()
             | :insufficient_plan
             | :feature_access_checker_failed
             | :invalid_state}
  def toggle_integration(%SlackIntegrationSchema{} = integration) do
    status = SlackIntegrationSchema.status(integration)

    if status in [:active, :paused] do
      with :ok <- Features.check_access(integration.user_id, :automations_allowed),
           do: SlackQueries.toggle_integration(integration)
    else
      {:error, :invalid_state}
    end
  end

  @spec reenable_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def reenable_integration(integration) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed),
         do: SlackQueries.enable_integration(integration)
  end

  # ============================================================================
  # OAuth flow
  # ============================================================================

  @doc """
  Persists a partial OAuth-completed integration record; see
  `Tymeslot.Slack.Install.complete_oauth/2`.

  The returned integration is in `:pending_oauth` status until `set_channel/2`
  is called with the user's channel selection.
  """
  @spec complete_oauth(integer(), OAuth.install()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error,
             Ecto.Changeset.t()
             | :insufficient_plan
             | :feature_access_checker_failed
             | :feature_disabled}
  defdelegate complete_oauth(user_id, install), to: Install

  @doc """
  Completes the OAuth flow Slack redirected back with; see
  `Tymeslot.Slack.Install.complete_oauth_callback/4`.

  Returns tagged errors for every refusal, never raises.
  """
  @spec complete_oauth_callback(integer(), String.t(), String.t(), String.t()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error,
             :oauth_unavailable
             | :invalid_state
             | :expired_state
             | :user_mismatch
             | term()}
  defdelegate complete_oauth_callback(user_id, code, state, redirect_uri), to: Install

  @doc """
  Sets the channel on a pending integration, transitioning it to `:active`.
  """
  @spec set_channel(SlackIntegrationSchema.t(), map()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def set_channel(%SlackIntegrationSchema{} = integration, attrs) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed),
         do: SlackQueries.set_channel(integration, attrs)
  end

  @doc """
  Clears the channel on an OAuth integration, demoting it back to
  `:pending_oauth`. The bot token and workspace info are preserved so the
  user can pick a new channel without redoing OAuth.
  """
  @spec disconnect(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def disconnect(%SlackIntegrationSchema{} = integration),
    do: SlackQueries.disconnect(integration)

  @doc """
  Lists channels the bot can post to, paginated transparently across
  `conversations.list` cursor responses.

  Returns a flat list of `%{id, name, is_private}` maps.
  """
  @spec list_channels(SlackIntegrationSchema.t()) ::
          {:ok, [%{id: String.t(), name: String.t(), is_private: boolean()}]}
          | {:error, term()}
  def list_channels(%SlackIntegrationSchema{} = integration) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed),
         {:ok, token} <- resolve_bot_token(integration) do
      fetch_all_channels(token, nil, [])
    end
  end

  defp fetch_all_channels(token, cursor, acc) do
    case API.list_conversations(token, cursor: cursor) do
      {:ok, body} ->
        channels = Enum.map(Map.get(body, "channels", []), &channel_summary/1)
        next_cursor = get_in(body, ["response_metadata", "next_cursor"])

        case next_cursor do
          empty when empty in [nil, ""] -> {:ok, acc ++ channels}
          cursor -> fetch_all_channels(token, cursor, acc ++ channels)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp channel_summary(%{"id" => id, "name" => name} = ch) do
    %{id: id, name: name, is_private: Map.get(ch, "is_private", false)}
  end

  # ============================================================================
  # Testing
  # ============================================================================

  @doc """
  Sends a single test message to the integration's channel and returns
  `:ok | {:error, reason}`. Used by the "Send test message" button in the UI.
  Refused, sending nothing, while the owner's plan doesn't include
  automations.
  """
  @spec test_integration(SlackIntegrationSchema.t()) :: :ok | {:error, term()}
  def test_integration(%SlackIntegrationSchema{} = integration) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed) do
      case integration.app_mode do
        :oauth -> send_test_via_oauth(integration)
        :webhook_url -> send_test_via_webhook(integration)
        other -> {:error, {:unknown_mode, other}}
      end
    end
  end

  defp send_test_via_oauth(integration) do
    with {:ok, token} <- resolve_bot_token(integration),
         {:ok, _body} <-
           API.post_message_via_token(
             token,
             integration.channel_id,
             MessageBuilder.build_test_blocks()
           ) do
      :ok
    end
  end

  defp send_test_via_webhook(integration) do
    case SlackIntegrationSchema.webhook_url(integration) do
      nil ->
        {:error, :no_webhook_url}

      url ->
        case API.post_message_via_webhook(url, MessageBuilder.build_test_blocks()) do
          {:ok, _body} -> :ok
          error -> error
        end
    end
  end

  # ============================================================================
  # Delivery
  # ============================================================================

  @impl Channel
  def schedule_for_event(user_id, event_type, meeting) do
    if slack_enabled?() do
      user_id
      |> SlackQueries.list_active_integrations_for_event(event_type)
      |> Enum.map(&{&1.id, schedule_delivery(&1, event_type, meeting)})
    else
      Logger.debug("Slack notifications disabled, skipping",
        user_id: user_id,
        event_type: event_type
      )

      []
    end
  end

  # The list query returns only deliverable integrations subscribed to the
  # event, so each one is scheduled as it stands.
  defp schedule_delivery(integration, event_type, meeting) do
    SlackWorker.schedule_delivery(
      integration.id,
      event_type,
      meeting.id,
      SeatView.participant_id(meeting)
    )
  end

  # ============================================================================
  # Token resolution
  # ============================================================================

  @spec resolve_bot_token(SlackIntegrationSchema.t()) :: {:ok, String.t()} | {:error, atom()}
  def resolve_bot_token(%SlackIntegrationSchema{} = integration) do
    case SlackIntegrationSchema.bot_token(integration) do
      nil -> {:error, :no_token}
      token -> {:ok, token}
    end
  end

  # ============================================================================
  # Delivery outcome tracking
  # ============================================================================

  @spec record_success(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_success(%SlackIntegrationSchema{} = integration) do
    SlackQueries.record_success(integration)
  end

  @spec record_failure(SlackIntegrationSchema.t(), String.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def record_failure(%SlackIntegrationSchema{} = integration, reason) do
    with {:ok, updated} <- SlackQueries.increment_failure(integration) do
      if updated.failure_count >= max_failure_count() do
        auto_disable(updated, "Too many consecutive failures: #{reason}")
      else
        {:ok, updated}
      end
    end
  end

  @spec auto_disable(SlackIntegrationSchema.t(), String.t()) ::
          {:ok, SlackIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def auto_disable(%SlackIntegrationSchema{} = integration, reason) do
    SlackQueries.update_state(integration, %{
      is_active: false,
      disabled_at: DateTime.utc_now(),
      disabled_reason: reason
    })
  end

  # ============================================================================
  # Delivery logs
  # ============================================================================

  @spec list_deliveries(integer(), keyword()) :: [Tymeslot.Slack.SlackDeliverySchema.t()]
  def list_deliveries(integration_id, opts) do
    SlackQueries.list_deliveries(integration_id, opts)
  end

  @spec get_delivery_stats(integer(), keyword()) :: map()
  def get_delivery_stats(integration_id, opts) do
    SlackQueries.get_delivery_stats(integration_id, opts)
  end

  @doc """
  Deletes OAuth installs never finished by picking a channel, once they are
  a day old. Each holds a workspace bot token; an install still in progress
  is younger than that, and a finished or disconnected integration is never
  touched (see `SlackQueries.delete_stale_pending_stubs/1`).
  """
  @spec prune_orphaned_stubs() :: {non_neg_integer(), nil | [term()]}
  def prune_orphaned_stubs do
    SlackQueries.delete_stale_pending_stubs(DateTime.add(DateTime.utc_now(), -1, :day))
  end

  @doc """
  Prunes Slack delivery log rows older than `days`. Called by the
  shared `DataRetentionWorker` so the per-attempt delivery log does not grow
  unbounded. Returns the `{deleted_count, nil}` tuple from `delete_all`.
  """
  @spec prune_deliveries(integer()) :: {non_neg_integer(), nil}
  def prune_deliveries(days) do
    SlackQueries.cleanup_old_deliveries(days)
  end

  # ============================================================================
  # Events & feature checks
  # ============================================================================

  @doc """
  The events a Slack integration can subscribe to, with their translated
  labels; see `EventOptions.options/0`.
  """
  @spec available_events() :: [EventOptions.option()]
  defdelegate available_events, to: EventOptions, as: :options

  @doc """
  Default event subscriptions used when a brand-new integration is created
  (e.g. immediately after an OAuth install, before the user has chosen which
  events to subscribe to).

  Returns the full list of valid events so that fresh integrations notify on
  everything by default; the user can prune later from the dashboard form.
  """
  @spec default_events_for_new_integration() :: [String.t()]
  def default_events_for_new_integration do
    SlackIntegrationSchema.valid_events()
  end

  @spec slack_enabled?() :: boolean()
  def slack_enabled? do
    Application.get_env(:tymeslot, :slack_notifications_allowed, false)
  end

  @doc """
  Returns true only when every prerequisite for the OAuth install flow is in
  place: the feature is enabled, the deployment has declared OAuth available
  via `:slack_oauth_available`, and a Slack client id is configured.

  Self-hosters without a Slack app of their own keep `:slack_oauth_available`
  false and only see the webhook URL flow in the dashboard.
  """
  @spec oauth_mode_available?() :: boolean()
  def oauth_mode_available? do
    slack_enabled?() and
      Application.get_env(:tymeslot, :slack_oauth_available, false) == true and
      not is_nil(Application.get_env(:tymeslot, :slack_client_id))
  end

  @spec max_failure_count() :: integer()
  defp max_failure_count, do: 10

  # ============================================================================
  # Error translation for the UI
  # ============================================================================

  @doc """
  Translates a low-level Slack API error tuple or a stored
  `disabled_reason` string into a user-facing message suitable for flash
  notifications and inline error banners; see
  `Tymeslot.Slack.ErrorMessages.translate_error/1`.
  """
  @spec translate_error(term()) :: String.t()
  defdelegate translate_error(reason), to: ErrorMessages
end
