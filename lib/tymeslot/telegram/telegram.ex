defmodule Tymeslot.Telegram do
  @moduledoc """
  Context module for Telegram integration management and delivery.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Telegram.{API, MessageBuilder, TelegramDeliverySchema, TelegramIntegrationSchema}
  alias Tymeslot.Telegram.TelegramQueries
  alias Tymeslot.Workers.TelegramWorker

  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage,
    do:
      {TelegramIntegrationSchema.__schema__(:source),
       TelegramIntegrationSchema.encrypted_credential_fields()}

  # ============================================================================
  # CRUD Operations
  # ============================================================================

  @spec list_integrations(integer()) :: [TelegramIntegrationSchema.t()]
  def list_integrations(user_id) do
    TelegramQueries.cleanup_orphaned_stubs(user_id)
    TelegramQueries.list_integrations(user_id)
  end

  @spec get_integration(integer(), integer()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id, user_id) do
    TelegramQueries.get_integration(id, user_id)
  end

  @spec create_integration(integer(), map()) ::
          {:ok, TelegramIntegrationSchema.t()}
          | {:error,
             Ecto.Changeset.t()
             | :insufficient_plan
             | :feature_access_checker_failed
             | :feature_disabled}
  def create_integration(user_id, attrs) do
    if telegram_enabled?() do
      with :ok <- Features.check_access(user_id, :automations_allowed) do
        attrs
        |> Map.put(:user_id, user_id)
        |> Map.put(:bot_mode, if(shared_bot_mode?(), do: "shared", else: "own"))
        |> TelegramQueries.create_integration()
      end
    else
      {:error, :feature_disabled}
    end
  end

  @spec update_integration(TelegramIntegrationSchema.t(), map()) ::
          {:ok, TelegramIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def update_integration(integration, attrs) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed) do
      TelegramQueries.update_integration(integration, attrs)
    end
  end

  @spec delete_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_integration(integration) do
    TelegramQueries.delete_integration(integration)
  end

  @spec toggle_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()}
          | {:error,
             Ecto.Changeset.t()
             | :insufficient_plan
             | :feature_access_checker_failed
             | :invalid_state}
  def toggle_integration(%TelegramIntegrationSchema{} = integration) do
    status = TelegramIntegrationSchema.derive_status(integration).status

    if status in [:active, :paused] do
      with :ok <- Features.check_access(integration.user_id, :automations_allowed) do
        TelegramQueries.toggle_integration(integration)
      end
    else
      {:error, :invalid_state}
    end
  end

  @spec reenable_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def reenable_integration(integration) do
    with :ok <- Features.check_access(integration.user_id, :automations_allowed) do
      TelegramQueries.enable_integration(integration)
    end
  end

  @spec disconnect_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, :own_bot_mode}
  def disconnect_integration(%TelegramIntegrationSchema{bot_mode: "own"}),
    do: {:error, :own_bot_mode}

  def disconnect_integration(%TelegramIntegrationSchema{} = integration) do
    TelegramQueries.update_integration(integration, %{chat_id: nil})
  end

  @spec reconnect_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t(), String.t()} | {:error, :own_bot_mode}
  def reconnect_integration(%TelegramIntegrationSchema{bot_mode: "own"}),
    do: {:error, :own_bot_mode}

  def reconnect_integration(%TelegramIntegrationSchema{} = integration) do
    token = generate_link_token()

    case TelegramQueries.update_integration(integration, %{chat_id: nil, link_token: token}) do
      {:ok, updated} ->
        {:ok, updated, build_deep_link(token)}

      error ->
        error
    end
  end

  # ============================================================================
  # Testing
  # ============================================================================

  @spec test_integration(TelegramIntegrationSchema.t()) :: :ok | {:error, String.t()}
  def test_integration(%TelegramIntegrationSchema{chat_id: nil}),
    do: {:error, "No chat ID configured"}

  def test_integration(%TelegramIntegrationSchema{} = integration) do
    case resolve_bot_token(integration) do
      {:ok, token} ->
        message = MessageBuilder.build_test_message()
        send_telegram_message(token, integration.chat_id, message)

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  # ============================================================================
  # Delivery
  # ============================================================================

  @spec trigger_integrations_for_event(integer(), String.t(), %{atom() => term()}) :: :ok
  def trigger_integrations_for_event(user_id, event_type, meeting) do
    if telegram_enabled?() do
      case Features.check_access(user_id, :automations_allowed) do
        :ok ->
          user_id
          |> TelegramQueries.list_active_integrations_for_event(event_type)
          |> Enum.each(&trigger_integration(&1, event_type, meeting))

        {:error, _reason} ->
          :ok
      end
    else
      Logger.debug("Telegram notifications disabled, skipping",
        user_id: user_id,
        event_type: event_type
      )
    end

    :ok
  end

  @spec trigger_integration(TelegramIntegrationSchema.t(), String.t(), %{atom() => term()}) ::
          :ok | {:error, term()}
  def trigger_integration(integration, event_type, meeting) do
    if TelegramIntegrationSchema.should_be_active?(integration) and
         TelegramIntegrationSchema.subscribed_to?(integration, event_type) do
      TelegramWorker.schedule_delivery(integration.id, event_type, meeting.id)
    else
      {:error, :integration_not_active}
    end
  end

  # ============================================================================
  # Token Resolution
  # ============================================================================

  @spec resolve_bot_token(TelegramIntegrationSchema.t()) :: {:ok, String.t()} | {:error, atom()}
  def resolve_bot_token(%TelegramIntegrationSchema{bot_mode: "shared"}) do
    case Application.get_env(:tymeslot, :telegram_bot_token) do
      nil -> {:error, :no_shared_token}
      token -> {:ok, token}
    end
  end

  def resolve_bot_token(%TelegramIntegrationSchema{bot_mode: "own"} = integration) do
    decrypted = TelegramIntegrationSchema.decrypt_token(integration)

    case decrypted.bot_token do
      nil -> {:error, :no_token}
      token -> {:ok, token}
    end
  end

  # ============================================================================
  # Account Linking (Shared Bot Mode)
  # ============================================================================

  @spec delete_pending_stubs(integer()) :: :ok
  def delete_pending_stubs(user_id) do
    TelegramQueries.delete_pending_stubs(user_id)
    :ok
  end

  @spec generate_link_token() :: String.t()
  def generate_link_token do
    Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  @spec refresh_link_token(TelegramIntegrationSchema.t()) ::
          {:ok, String.t()} | {:error, term()}
  def refresh_link_token(%TelegramIntegrationSchema{} = integration) do
    token = generate_link_token()

    case TelegramQueries.update_integration(integration, %{link_token: token}) do
      {:ok, _updated} -> {:ok, token}
      error -> error
    end
  end

  @spec build_deep_link(String.t()) :: String.t()
  def build_deep_link(token) do
    bot_username = Application.get_env(:tymeslot, :telegram_bot_username, "TymeslotBot")
    "https://t.me/#{bot_username}?start=#{token}"
  end

  @spec handle_start_payload(String.t(), String.t() | integer()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, atom()}
  def handle_start_payload(token, chat_id) do
    chat_id_str = to_string(chat_id)

    case TelegramQueries.find_by_link_token(token) do
      {:ok, %TelegramIntegrationSchema{bot_mode: "shared"} = integration} ->
        case TelegramQueries.update_integration(integration, %{
               chat_id: chat_id_str,
               link_token: nil
             }) do
          {:ok, updated} ->
            Phoenix.PubSub.broadcast(
              Tymeslot.PubSub,
              "telegram_link:#{updated.user_id}",
              {:telegram_linked, integration.id, chat_id_str}
            )

            {:ok, updated}

          error ->
            error
        end

      {:ok, _integration} ->
        {:error, :wrong_bot_mode}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # ============================================================================
  # Delivery Outcome Tracking
  # ============================================================================

  @spec record_success(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_success(%TelegramIntegrationSchema{} = integration) do
    TelegramQueries.record_success(integration)
  end

  @spec record_failure(TelegramIntegrationSchema.t(), String.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def record_failure(%TelegramIntegrationSchema{} = integration, reason) do
    with {:ok, updated} <- TelegramQueries.increment_failure(integration) do
      if updated.failure_count >= TelegramIntegrationSchema.max_failure_count() do
        TelegramQueries.update_integration(updated, %{
          is_active: false,
          disabled_at: DateTime.utc_now(),
          disabled_reason: "Too many consecutive failures: #{reason}"
        })
      else
        {:ok, updated}
      end
    end
  end

  @spec auto_disable(TelegramIntegrationSchema.t(), String.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def auto_disable(%TelegramIntegrationSchema{} = integration, reason) do
    TelegramQueries.update_integration(integration, %{
      is_active: false,
      disabled_at: DateTime.utc_now(),
      disabled_reason: reason
    })
  end

  # ============================================================================
  # Delivery Logs
  # ============================================================================

  @spec list_deliveries(integer(), keyword()) :: [TelegramDeliverySchema.t()]
  def list_deliveries(integration_id, opts \\ []) do
    TelegramQueries.list_deliveries(integration_id, opts)
  end

  @spec get_delivery_stats(integer(), keyword()) :: %{
          required(:total) => non_neg_integer(),
          required(:successful) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          required(:success_rate) => float(),
          required(:period_days) => non_neg_integer()
        }
  def get_delivery_stats(integration_id, opts \\ []) do
    TelegramQueries.get_delivery_stats(integration_id, opts)
  end

  @doc """
  Prunes Telegram delivery log rows older than `days` (default 60). Called by
  the shared `DataRetentionWorker` so the per-attempt delivery log does not
  grow unbounded. Returns the `{deleted_count, nil}` tuple from `delete_all`.
  """
  @spec prune_deliveries(integer()) :: {non_neg_integer(), nil}
  def prune_deliveries(days \\ 60) do
    TelegramQueries.cleanup_old_deliveries(days)
  end

  # ============================================================================
  # Events & Feature Checks
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

  @spec shared_bot_mode?() :: boolean()
  def shared_bot_mode? do
    Application.get_env(:tymeslot, :telegram_shared_bot, false)
  end

  @spec telegram_enabled?() :: boolean()
  def telegram_enabled? do
    Application.get_env(:tymeslot, :telegram_notifications_allowed, false)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp send_telegram_message(bot_token, chat_id, text) do
    case API.send_message(bot_token, chat_id, text) do
      {:ok, status, _body} when status >= 200 and status < 300 ->
        :ok

      {:ok, status, body} ->
        {:error, "Telegram API returned #{status}: #{truncate(body, 200)}"}

      {:error, reason} ->
        {:error, "Connection failed: #{reason}"}
    end
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
