defmodule Tymeslot.Telegram do
  @moduledoc """
  Context module for Telegram integration management and delivery.
  """

  @behaviour Tymeslot.Notifications.Channel
  @behaviour Tymeslot.Security.EncryptedStorage

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.Channel
  alias Tymeslot.Notifications.EventOptions
  alias Tymeslot.Repo
  alias Tymeslot.Security.SharedSecret
  alias Tymeslot.Security.Token
  alias Tymeslot.Telegram.{API, MessageBuilder, TelegramDeliverySchema, TelegramIntegrationSchema}
  alias Tymeslot.Telegram.TelegramQueries
  alias Tymeslot.Workers.TelegramWorker

  @link_token_ttl_ms :timer.minutes(10)

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
        |> Map.put(:bot_mode, installation_bot_mode())
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
          {:ok, TelegramIntegrationSchema.t()} | {:error, :own_bot_mode | :not_found}
  def disconnect_integration(%TelegramIntegrationSchema{bot_mode: "own"}),
    do: {:error, :own_bot_mode}

  def disconnect_integration(%TelegramIntegrationSchema{} = integration) do
    TelegramQueries.update_link_state(integration, %{chat_id: nil})
  end

  @spec reconnect_integration(TelegramIntegrationSchema.t()) ::
          {:ok, TelegramIntegrationSchema.t(), String.t()}
          | {:error, :own_bot_mode | :not_found | Ecto.Changeset.t()}
  def reconnect_integration(%TelegramIntegrationSchema{bot_mode: "own"}),
    do: {:error, :own_bot_mode}

  def reconnect_integration(%TelegramIntegrationSchema{} = integration) do
    token = generate_link_token()

    with {:ok, updated} <-
           TelegramQueries.update_link_state(integration, %{chat_id: nil, link_token: token}) do
      {:ok, updated, build_deep_link(token)}
    end
  end

  # ============================================================================
  # Testing
  # ============================================================================

  @typedoc "Why a test message did not go through; see `translate_error/1`."
  @type test_error ::
          :no_chat
          | :no_token
          | :no_shared_token
          | {:api_error, non_neg_integer(), String.t()}
          | {:transport_error, String.t()}

  @doc """
  Sends a test message to the integration's chat. A failure is a reason,
  not text; `translate_error/1` renders it for the organiser.
  Refused, sending nothing, while the owner's plan doesn't include
  automations; an integration not yet saved names its owner in `user_id`.
  """
  @spec test_integration(TelegramIntegrationSchema.t()) ::
          :ok | {:error, test_error() | Features.access_error()}
  def test_integration(%TelegramIntegrationSchema{user_id: user_id} = integration) do
    with :ok <- Features.check_access(user_id, :automations_allowed),
         do: send_test(integration)
  end

  defp send_test(%TelegramIntegrationSchema{chat_id: nil}), do: {:error, :no_chat}

  defp send_test(%TelegramIntegrationSchema{} = integration) do
    case resolve_bot_token(integration) do
      {:ok, token} ->
        message = MessageBuilder.build_test_message()
        send_telegram_message(token, integration.chat_id, message)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Delivery
  # ============================================================================

  @impl Channel
  def schedule_for_event(user_id, event_type, meeting) do
    if telegram_enabled?() do
      user_id
      |> TelegramQueries.list_active_integrations_for_event(event_type)
      |> Enum.map(&{&1.id, schedule_delivery(&1, event_type, meeting)})
    else
      Logger.debug("Telegram notifications disabled, skipping",
        user_id: user_id,
        event_type: event_type
      )

      []
    end
  end

  # The list query returns only deliverable integrations subscribed to the
  # event, so each one is scheduled as it stands.
  defp schedule_delivery(integration, event_type, meeting) do
    TelegramWorker.schedule_delivery(
      integration.id,
      event_type,
      meeting.id,
      SeatView.participant_id(meeting)
    )
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

  @doc """
  How long a link token stays valid after it is issued, in milliseconds.
  """
  @spec link_token_ttl_ms() :: pos_integer()
  def link_token_ttl_ms, do: @link_token_ttl_ms

  @doc """
  Starts linking a new Telegram chat through the shared bot.

  Access is checked before anything is written. The user's never-linked setup
  stubs are then replaced by a fresh one holding a new link token, in one
  transaction; integrations that were linked and later disconnected are kept.
  The default name is translated in the calling process's locale.
  """
  @spec start_link_flow(integer()) ::
          {:ok, TelegramIntegrationSchema.t(), String.t()}
          | {:error,
             :feature_disabled
             | :own_bot_mode
             | :insufficient_plan
             | :feature_access_checker_failed
             | Ecto.Changeset.t()}
  def start_link_flow(user_id) do
    with :ok <- check_link_flow_access(user_id),
         {:ok, stub} <- replace_pending_stubs(user_id) do
      {:ok, stub, build_deep_link(stub.link_token)}
    end
  end

  @doc """
  Discards a setup stub the user abandoned. Does nothing if the stub has been
  linked since it was loaded, or no longer exists.
  """
  @spec discard_pending(TelegramIntegrationSchema.t()) :: :ok
  def discard_pending(%TelegramIntegrationSchema{id: id, user_id: user_id}) do
    TelegramQueries.delete_pending_stub(id, user_id)
    :ok
  end

  @spec generate_link_token() :: String.t()
  def generate_link_token do
    Token.generate(24)
  end

  @spec refresh_link_token(TelegramIntegrationSchema.t()) ::
          {:ok, String.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def refresh_link_token(%TelegramIntegrationSchema{} = integration) do
    token = generate_link_token()

    with {:ok, _updated} <- TelegramQueries.update_link_state(integration, %{link_token: token}) do
      {:ok, token}
    end
  end

  @spec build_deep_link(String.t()) :: String.t()
  def build_deep_link(token) do
    bot_username = Application.get_env(:tymeslot, :telegram_bot_username, "TymeslotBot")
    "https://t.me/#{bot_username}?start=#{token}"
  end

  @spec handle_start_payload(String.t(), String.t() | integer()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def handle_start_payload(token, chat_id) do
    chat_id_str = to_string(chat_id)
    issued_after = DateTime.add(DateTime.utc_now(), -@link_token_ttl_ms, :millisecond)

    case TelegramQueries.find_by_link_token(token, issued_after) do
      {:ok, %TelegramIntegrationSchema{bot_mode: "shared"} = integration} ->
        case TelegramQueries.update_link_state(integration, %{
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
  def record_failure(%TelegramIntegrationSchema{} = integration, _reason) do
    with {:ok, updated} <- TelegramQueries.increment_failure(integration) do
      if updated.failure_count >= TelegramIntegrationSchema.max_failure_count() do
        auto_disable(updated, "too_many_failures")
      else
        {:ok, updated}
      end
    end
  end

  @spec auto_disable(TelegramIntegrationSchema.t(), String.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def auto_disable(%TelegramIntegrationSchema{} = integration, reason) do
    TelegramQueries.update_state(integration, %{
      is_active: false,
      disabled_at: DateTime.utc_now(),
      disabled_reason: reason
    })
  end

  @doc """
  Rewrites the chat id after Telegram reports a group's supergroup upgrade.

  Telegram issues a fresh chat id when a group upgrades to a supergroup; the
  old id is permanently dead. This does not go through `update_integration/2`
  because it is a delivery-time correction, not a user-initiated edit, and
  must not be gated behind a feature-access check.
  """
  @spec migrate_chat_id(TelegramIntegrationSchema.t(), String.t()) ::
          {:ok, TelegramIntegrationSchema.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def migrate_chat_id(%TelegramIntegrationSchema{} = integration, new_chat_id) do
    TelegramQueries.update_link_state(integration, %{chat_id: new_chat_id})
  end

  # ============================================================================
  # Delivery Logs
  # ============================================================================

  @spec list_deliveries(integer(), keyword()) :: [TelegramDeliverySchema.t()]
  def list_deliveries(integration_id, opts) do
    TelegramQueries.list_deliveries(integration_id, opts)
  end

  @spec get_delivery_stats(integer(), keyword()) :: %{
          required(:total) => non_neg_integer(),
          required(:successful) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          required(:success_rate) => float(),
          required(:period_days) => non_neg_integer()
        }
  def get_delivery_stats(integration_id, opts) do
    TelegramQueries.get_delivery_stats(integration_id, opts)
  end

  @doc """
  Prunes Telegram delivery log rows older than `days`. Called by
  the shared `DataRetentionWorker` so the per-attempt delivery log does not
  grow unbounded. Returns the `{deleted_count, nil}` tuple from `delete_all`.
  """
  @spec prune_deliveries(integer()) :: {non_neg_integer(), nil}
  def prune_deliveries(days) do
    TelegramQueries.cleanup_old_deliveries(days)
  end

  @doc """
  Deletes abandoned setup stubs: integrations a user created by starting the
  link flow and never finished linking. Called by the shared
  `DataRetentionWorker` rather than by any read path; listings hide expired
  stubs on their own. Returns the `{deleted_count, nil}` tuple from
  `delete_all`.
  """
  @spec prune_orphaned_stubs() :: {non_neg_integer(), nil | [term()]}
  def prune_orphaned_stubs do
    TelegramQueries.cleanup_orphaned_stubs()
  end

  # ============================================================================
  # Events & Feature Checks
  # ============================================================================

  @doc """
  The events a Telegram integration can subscribe to, with their translated
  labels; see `EventOptions.options/0`.
  """
  @spec available_events() :: [EventOptions.option()]
  defdelegate available_events, to: EventOptions, as: :options

  @spec shared_bot_mode?() :: boolean()
  def shared_bot_mode? do
    Application.get_env(:tymeslot, :telegram_shared_bot, false)
  end

  @doc """
  The bot mode the integration form validates and renders against. An edit
  follows the integration's own mode, which never changes after creation;
  creating one follows the installation's, which is the mode it will get.
  """
  @spec form_bot_mode(:create | :edit, TelegramIntegrationSchema.t() | nil) :: String.t()
  def form_bot_mode(:edit, %TelegramIntegrationSchema{bot_mode: bot_mode}), do: bot_mode
  def form_bot_mode(_mode, _integration), do: installation_bot_mode()

  defp installation_bot_mode, do: if(shared_bot_mode?(), do: "shared", else: "own")

  @spec telegram_enabled?() :: boolean()
  def telegram_enabled? do
    Application.get_env(:tymeslot, :telegram_notifications_allowed, false)
  end

  @doc """
  Whether `received` is the shared bot's webhook secret, as Telegram echoes it
  in the `X-Telegram-Bot-Api-Secret-Token` header.

  An unset or empty configured secret never matches, so a deployment that sets
  `TELEGRAM_WEBHOOK_SECRET` to an empty string refuses every update rather
  than accepting the ones that send an empty header.
  """
  @spec valid_webhook_secret?(String.t() | nil) :: boolean()
  def valid_webhook_secret?(received) do
    SharedSecret.matches?(received, Application.get_env(:tymeslot, :telegram_webhook_secret))
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp check_link_flow_access(user_id) do
    cond do
      not telegram_enabled?() -> {:error, :feature_disabled}
      not shared_bot_mode?() -> {:error, :own_bot_mode}
      true -> Features.check_access(user_id, :automations_allowed)
    end
  end

  defp replace_pending_stubs(user_id) do
    attrs = %{
      user_id: user_id,
      bot_mode: "shared",
      name: dgettext("dashboard_automation_chat", "My Telegram"),
      events: ["meeting.created"]
    }

    Repo.transaction(fn ->
      TelegramQueries.delete_pending_stubs(user_id)

      case TelegramQueries.create_link_stub(attrs, generate_link_token()) do
        {:ok, stub} -> stub
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp send_telegram_message(bot_token, chat_id, text) do
    case API.send_message(bot_token, chat_id, text) do
      {:ok, status, _body} when status >= 200 and status < 300 ->
        :ok

      {:ok, status, body} ->
        {:error, {:api_error, status, api_description(body)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  # Telegram explains a refusal in the body's `description`; anything else
  # is shown cut short rather than in full.
  defp api_description(body) do
    case Jason.decode(body) do
      {:ok, %{"description" => description}} when is_binary(description) -> description
      _other -> truncate(body, 200)
    end
  end

  @doc "Renders a `test_integration/1` failure for the organiser, in their language."
  @spec translate_error(test_error()) :: String.t()
  def translate_error(:no_chat),
    do: dgettext("dashboard_automation_chat", "No chat is linked to this integration yet")

  def translate_error(:no_token),
    do: dgettext("dashboard_automation_chat", "The bot token is missing")

  def translate_error(:no_shared_token),
    do: dgettext("dashboard_automation_chat", "The shared Telegram bot is not configured")

  def translate_error({:api_error, status, description}) do
    dgettext(
      "dashboard_automation_chat",
      "Telegram refused the message (%{status}): %{description}",
      status: status,
      description: description
    )
  end

  def translate_error({:transport_error, _reason}),
    do: dgettext("dashboard_automation_chat", "Could not reach Telegram")

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
