defmodule Tymeslot.Telegram do
  @moduledoc """
  Context module for Telegram integration management and delivery.
  """

  require Logger

  alias Tymeslot.DatabaseQueries.TelegramQueries
  alias Tymeslot.DatabaseSchemas.TelegramIntegrationSchema
  alias Tymeslot.Features
  alias Tymeslot.Telegram.{LinkToken, MessageBuilder}
  alias Tymeslot.Workers.TelegramWorker

  # ============================================================================
  # CRUD Operations
  # ============================================================================

  @spec list_integrations(integer()) :: [TelegramIntegrationSchema.t()]
  def list_integrations(user_id) do
    TelegramQueries.list_integrations(user_id)
  end

  @spec get_integration(integer(), integer()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, :not_found}
  def get_integration(id, user_id) do
    TelegramQueries.get_integration(id, user_id)
  end

  @spec create_integration(integer(), map()) ::
          {:ok, TelegramIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def create_integration(user_id, attrs) do
    with :ok <- Features.check_access(user_id, :automations_allowed) do
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put(:bot_mode, if(shared_bot_mode?(), do: "shared", else: "own"))
      |> TelegramQueries.create_integration()
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
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed | :invalid_state}
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
    case TelegramQueries.update_integration(integration, %{chat_id: nil}) do
      {:ok, updated} ->
        token = generate_link_token(integration.user_id, integration.id)
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

  @spec trigger_integrations_for_event(integer(), String.t(), map()) :: :ok
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

  @spec trigger_integration(TelegramIntegrationSchema.t(), String.t(), map()) ::
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

  @spec generate_link_token(integer(), integer()) :: String.t()
  def generate_link_token(user_id, integration_id) do
    LinkToken.sign(user_id, integration_id)
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

    case LinkToken.verify(token) do
      {:ok, {user_id, integration_id}} ->
        case TelegramQueries.get_integration(integration_id, user_id) do
          {:ok, integration} ->
            case TelegramQueries.update_integration(integration, %{chat_id: chat_id_str}) do
              {:ok, updated} ->
                Phoenix.PubSub.broadcast(
                  Tymeslot.PubSub,
                  "telegram_link:#{user_id}",
                  {:telegram_linked, integration_id, chat_id_str}
                )

                {:ok, updated}

              error ->
                error
            end

          error ->
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Delivery Logs
  # ============================================================================

  @spec list_deliveries(integer(), keyword()) :: [map()]
  def list_deliveries(integration_id, opts \\ []) do
    TelegramQueries.list_deliveries(integration_id, opts)
  end

  @spec get_delivery_stats(integer(), keyword()) :: map()
  def get_delivery_stats(integration_id, opts \\ []) do
    TelegramQueries.get_delivery_stats(integration_id, opts)
  end

  # ============================================================================
  # Events & Feature Checks
  # ============================================================================

  @spec available_events() :: [map()]
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
    url = "https://api.telegram.org/bot#{bot_token}/sendMessage"

    body =
      Jason.encode!(%{
        chat_id: chat_id,
        text: text,
        parse_mode: "HTML",
        disable_web_page_preview: true
      })

    headers = [{"content-type", "application/json"}]

    case http_client().post(url, body, headers, receive_timeout: 10_000) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "Telegram API returned #{status}: #{truncate(body, 200)}"}

      {:error, %{reason: reason}} ->
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Connection failed: #{inspect(reason)}"}
    end
  end

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max,
    do: String.slice(text, 0, max) <> "..."

  defp truncate(text, _max), do: text

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end
end
