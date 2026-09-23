defmodule Tymeslot.Slack do
  @moduledoc """
  Context module for Slack integration management and delivery.

  Public boundary for the Slack feature — controllers, LiveViews, and workers
  must call into this module rather than reaching into queries, schemas or the
  HTTP client directly.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Repo
  alias Tymeslot.Slack.{API, MessageBuilder, OAuth, SlackIntegrationSchema, SlackQueries}
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
    create_integration(user_id, Map.put(attrs, :app_mode, "webhook_url"))
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
      with :ok <- Features.check_access(integration.user_id, :automations_allowed) do
        SlackQueries.toggle_integration(integration)
      end
    else
      {:error, :invalid_state}
    end
  end

  @spec reenable_integration(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def reenable_integration(integration) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed) do
      SlackQueries.enable_integration(integration)
    end
  end

  # ============================================================================
  # OAuth flow
  # ============================================================================

  @doc """
  Persists a partial OAuth-completed integration record using `oauth_init_changeset/2`.

  Takes the install map returned by `Tymeslot.Slack.OAuth.exchange_code/2`
  and maps it onto the integration: the display name defaults to the workspace
  name so the dashboard has something to show before the user edits it, and
  the integration subscribes to every event until the user prunes the list.

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
  def complete_oauth(user_id, install) do
    if slack_enabled?() do
      with :ok <- Features.check_access(user_id, :automations_allowed) do
        stub_attrs = install_to_attrs(user_id, install)

        transaction_result =
          Repo.transaction(fn ->
            SlackQueries.delete_pending_stubs(user_id)

            case SlackQueries.create_oauth_stub(stub_attrs) do
              {:ok, integration} -> integration
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)

        case transaction_result do
          {:ok, integration} -> {:ok, integration}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, :feature_disabled}
    end
  end

  defp install_to_attrs(user_id, install) do
    %{
      user_id: user_id,
      app_mode: "oauth",
      name: install[:team_name] || "Slack",
      bot_token: install[:bot_token],
      team_id: install[:team_id],
      team_name: install[:team_name],
      authed_user_id: install[:authed_user_id],
      scope: install[:scope],
      events: default_events_for_new_integration()
    }
  end

  @doc """
  Sets the channel on a pending integration, transitioning it to `:active`.
  """
  @spec set_channel(SlackIntegrationSchema.t(), map()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def set_channel(%SlackIntegrationSchema{} = integration, attrs) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed) do
      SlackQueries.set_channel(integration, attrs)
    end
  end

  @doc """
  Clears the channel on an OAuth integration, demoting it back to
  `:pending_oauth`. The bot token and workspace info are preserved so the
  user can pick a new channel without redoing OAuth.
  """
  @spec disconnect(SlackIntegrationSchema.t()) ::
          {:ok, SlackIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def disconnect(%SlackIntegrationSchema{} = integration) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed) do
      SlackQueries.disconnect(integration)
    end
  end

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
  """
  @spec test_integration(SlackIntegrationSchema.t()) :: :ok | {:error, term()}
  def test_integration(%SlackIntegrationSchema{} = integration) do
    case integration.app_mode do
      "oauth" -> send_test_via_oauth(integration)
      "webhook_url" -> send_test_via_webhook(integration)
      other -> {:error, {:unknown_mode, other}}
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

  @spec trigger_integrations_for_event(integer(), String.t(), %{atom() => term()}) :: :ok
  def trigger_integrations_for_event(user_id, event_type, meeting) do
    if slack_enabled?() do
      case Features.check_access(user_id, :automations_allowed) do
        :ok ->
          user_id
          |> SlackQueries.list_active_integrations_for_event(event_type)
          |> Enum.each(&trigger_integration(&1, event_type, meeting))

        {:error, _reason} ->
          :ok
      end
    else
      Logger.debug("Slack notifications disabled, skipping",
        user_id: user_id,
        event_type: event_type
      )
    end

    :ok
  end

  @spec trigger_integration(SlackIntegrationSchema.t(), String.t(), %{atom() => term()}) ::
          :ok | {:error, term()}
  def trigger_integration(integration, event_type, meeting) do
    if SlackIntegrationSchema.status(integration) == :active and
         SlackIntegrationSchema.subscribed_to?(integration, event_type) do
      SlackWorker.schedule_delivery(integration.id, event_type, meeting.id)
    else
      {:error, :integration_not_active}
    end
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
        SlackQueries.update_state(updated, %{
          is_active: false,
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Too many consecutive failures: #{reason}"
        })
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

  @spec available_events() :: [
          %{
            required(:value) => String.t(),
            required(:label) => String.t(),
            required(:description) => String.t()
          }
        ]
  def available_events do
    [
      %{
        value: "meeting.created",
        label: "Meeting Created",
        description: "Triggered when a new booking is created"
      },
      %{
        value: "meeting.cancelled",
        label: "Meeting Cancelled",
        description: "Triggered when a booking is cancelled"
      },
      %{
        value: "meeting.rescheduled",
        label: "Meeting Rescheduled",
        description: "Triggered when a booking time is changed"
      }
    ]
  end

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
  notifications and inline error banners.

  Accepts the exact `{:error, term()}` shapes returned by `test_integration/1`,
  delivery worker callbacks, and `set_channel/2` failures.
  """
  @spec translate_error(term()) :: String.t()
  def translate_error({:error, reason}), do: translate_error(reason)
  def translate_error({:slack_error, code, _body}), do: translate_error_code(code)
  def translate_error(code) when is_binary(code), do: translate_error_code(code)

  def translate_error(:no_token),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack credentials are missing. Reconnect to continue."
      )

  def translate_error(:no_webhook_url),
    do: dgettext("dashboard_automation_chat", "Webhook URL is missing. Add it again to continue.")

  def translate_error(reason) when reason in [:insufficient_plan, :pro_required],
    do:
      dgettext(
        "dashboard_automation_chat",
        "Your plan does not include Slack notifications. Upgrade to connect Slack."
      )

  def translate_error(:feature_access_checker_failed),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Could not verify your plan right now. Please try again in a moment."
      )

  def translate_error(:feature_disabled),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack notifications are not enabled on this deployment."
      )

  def translate_error(:oauth_unavailable),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack app install is not available on this deployment. Use a webhook URL instead."
      )

  def translate_error(:missing_bot_token),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack app is not configured as a bot token app. Check your Slack app settings and ensure the OAuth scopes grant a bot token."
      )

  def translate_error({:unknown_mode, _mode}),
    do: dgettext("dashboard_automation_chat", "Slack integration is misconfigured.")

  def translate_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [{_field, {"workspace already connected", _opts}} | _rest] ->
        dgettext(
          "dashboard_automation_chat",
          "This Slack workspace is already connected. Disconnect the existing integration first."
        )

      [{field, {msg, _opts}} | _rest] ->
        "#{field} #{msg}"

      _other ->
        dgettext("dashboard_automation_chat", "Could not save Slack integration.")
    end
  end

  def translate_error(other), do: unknown_error(inspect(other))

  defp translate_error_code("channel_not_found"),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Channel not accessible. If it's a private channel, invite the Tymeslot bot first."
      )

  defp translate_error_code(code) when code in ["token_revoked", "account_inactive"],
    do:
      dgettext(
        "dashboard_automation_chat",
        "Slack authorisation was revoked. Reconnect to continue."
      )

  defp translate_error_code("not_in_channel"),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Bot is not in this channel. Either pick a public channel or invite the bot."
      )

  defp translate_error_code("ratelimited"),
    do: dgettext("dashboard_automation_chat", "Slack is rate-limiting. Try again in a minute.")

  defp translate_error_code("webhook_url_revoked"),
    do:
      dgettext(
        "dashboard_automation_chat",
        "Webhook URL was revoked in Slack. Generate a new one."
      )

  defp translate_error_code(other), do: unknown_error(other)

  defp unknown_error(detail),
    do: dgettext("dashboard_automation_chat", "Slack error: %{error}", error: detail)
end
