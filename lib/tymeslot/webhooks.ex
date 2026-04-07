defmodule Tymeslot.Webhooks do
  @moduledoc """
  Context module for webhook management and delivery.

  Provides the public API for:
  - CRUD operations on webhooks
  - Testing webhook connections
  - Triggering webhook deliveries
  - Viewing delivery logs and statistics
  """

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Security.UrlValidation
  alias Tymeslot.Webhooks.{PayloadBuilder, WebhookDeliverySchema, WebhookQueries, WebhookSchema}
  alias Tymeslot.Workers.WebhookWorker

  # ============================================================================
  # CRUD Operations
  # ============================================================================

  @doc """
  Lists all webhooks for a user.
  Returns webhooks with decrypted tokens.
  """
  @spec list_webhooks(integer()) :: [WebhookSchema.t()]
  def list_webhooks(user_id) do
    user_id
    |> WebhookQueries.list_webhooks()
    |> Enum.map(&WebhookSchema.decrypt_token/1)
  end

  @doc """
  Gets a single webhook by ID for a specific user.
  Returns the webhook with decrypted token.
  """
  @spec get_webhook(integer(), integer()) :: {:ok, WebhookSchema.t()} | {:error, :not_found}
  def get_webhook(id, user_id) do
    case WebhookQueries.get_webhook(id, user_id) do
      {:ok, webhook} -> {:ok, WebhookSchema.decrypt_token(webhook)}
      error -> error
    end
  end

  @doc """
  Creates a new webhook for a user.
  """
  @spec create_webhook(integer(), map()) ::
          {:ok, WebhookSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def create_webhook(user_id, attrs) do
    with :ok <- Features.check_access(user_id, :automations_allowed) do
      attrs
      |> Map.put(:user_id, user_id)
      |> WebhookQueries.create_webhook()
    end
  end

  @doc """
  Updates a webhook.
  """
  @spec update_webhook(WebhookSchema.t(), map()) ::
          {:ok, WebhookSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def update_webhook(webhook, attrs) do
    with :ok <- Features.check_access(webhook.user_id, :automations_allowed) do
      WebhookQueries.update_webhook(webhook, attrs)
    end
  end

  @doc """
  Deletes a webhook.
  """
  @spec delete_webhook(WebhookSchema.t()) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_webhook(webhook) do
    WebhookQueries.delete_webhook(webhook)
  end

  @doc """
  Toggles webhook active status.
  """
  @spec toggle_webhook(WebhookSchema.t()) ::
          {:ok, WebhookSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def toggle_webhook(webhook) do
    with :ok <- Features.check_access(webhook.user_id, :automations_allowed) do
      WebhookQueries.toggle_webhook(webhook)
    end
  end

  @doc """
  Records a failed webhook delivery.

  Atomically increments the failure count and, if the threshold (10 consecutive
  failures) is reached, auto-disables the webhook.
  """
  @spec record_delivery_failure(WebhookSchema.t(), String.t()) ::
          {:ok, WebhookSchema.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def record_delivery_failure(webhook, reason) do
    with {:ok, updated} <- WebhookQueries.increment_failure_count(webhook, reason) do
      if updated.failure_count >= 10 do
        WebhookQueries.disable_webhook(updated, "Too many consecutive failures: #{reason}")
      else
        {:ok, updated}
      end
    end
  end

  @doc """
  Re-enables a disabled webhook (resets failure count).
  """
  @spec enable_webhook(WebhookSchema.t()) ::
          {:ok, WebhookSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def enable_webhook(webhook) do
    with :ok <- Features.check_access(webhook.user_id, :automations_allowed) do
      WebhookQueries.enable_webhook(webhook)
    end
  end

  @doc """
  Regenerates the webhook token.
  """
  @spec regenerate_token(WebhookSchema.t()) ::
          {:ok, WebhookSchema.t()}
          | {:error, Ecto.Changeset.t() | :insufficient_plan | :feature_access_checker_failed}
  def regenerate_token(%WebhookSchema{} = webhook) do
    with :ok <- Features.check_access(webhook.user_id, :automations_allowed) do
      # Passing nil for webhook_token triggers generation in the changeset
      WebhookQueries.update_webhook(webhook, %{webhook_token: nil})
    end
  end

  @doc """
  Builds the standard headers for a webhook request.
  """
  @spec build_headers(map(), String.t() | nil) :: [{String.t(), String.t()}]
  def build_headers(_payload, token) do
    base_headers = [
      {"Content-Type", "application/json"},
      {"User-Agent", "Tymeslot-Webhooks/1.0"},
      {"X-Tymeslot-Timestamp", DateTime.to_iso8601(DateTime.utc_now())}
    ]

    if token do
      [{"X-Tymeslot-Token", token} | base_headers]
    else
      base_headers
    end
  end

  # ============================================================================
  # Validation & Testing
  # ============================================================================

  @doc """
  Tests a webhook connection by sending a test payload.
  """
  @spec test_webhook_connection(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def test_webhook_connection(url, token \\ nil) do
    strict? = Application.get_env(:tymeslot, :environment, :prod) == :prod

    with :ok <-
           UrlValidation.validate_http_url(url,
             block_private_ips: strict?,
             enforce_https: strict?
           ) do
      payload = PayloadBuilder.build_test_payload()
      headers = build_headers(payload, token)

      case http_client().post(url, Jason.encode!(payload), headers, receive_timeout: 10_000) do
        {:ok, %{status: status}} when status >= 200 and status < 300 ->
          :ok

        {:ok, %{status: status}} ->
          {:error, "Webhook returned status #{status}"}

        {:error, %{reason: reason}} ->
          {:error, "Connection failed: #{inspect(reason)}"}

        {:error, reason} ->
          {:error, "Connection failed: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Validates a webhook URL format.
  Checks for protocol and prevents SSRF by blocking private IP ranges in production.
  """
  @spec validate_webhook_url(String.t()) :: :ok | {:error, String.t()}
  def validate_webhook_url(url) do
    strict? = Application.get_env(:tymeslot, :environment, :prod) == :prod

    UrlValidation.validate_http_url(url,
      block_private_ips: strict?,
      enforce_https: strict?
    )
  end

  # ============================================================================
  # Delivery
  # ============================================================================

  @doc """
  Triggers a webhook delivery by scheduling it via Oban.
  """
  @spec trigger_webhook(WebhookSchema.t(), String.t(), MeetingSchema.t()) ::
          :ok | {:error, term()}
  def trigger_webhook(webhook, event_type, meeting) do
    if WebhookSchema.should_be_active?(webhook) and
         WebhookSchema.subscribed_to?(webhook, event_type) do
      WebhookWorker.schedule_delivery(webhook.id, event_type, meeting.id)
    else
      {:error, :webhook_not_active}
    end
  end

  @doc """
  Triggers all webhooks for a user and event type.
  Checks feature access before triggering webhooks.
  """
  @spec trigger_webhooks_for_event(integer(), String.t(), MeetingSchema.t()) :: :ok
  def trigger_webhooks_for_event(user_id, event_type, meeting) do
    # Check if user has access to automation features
    case Features.check_access(user_id, :automations_allowed) do
      :ok ->
        user_id
        |> WebhookQueries.list_active_webhooks_for_event(event_type)
        |> Enum.each(fn webhook ->
          case trigger_webhook(webhook, event_type, meeting) do
            :ok ->
              Logger.debug("Scheduled webhook delivery",
                webhook_id: webhook.id,
                event_type: event_type
              )

            {:error, reason} ->
              Logger.warning("Failed to schedule webhook delivery",
                webhook_id: webhook.id,
                event_type: event_type,
                reason: inspect(reason)
              )
          end
        end)

      {:error, :insufficient_plan} ->
        Logger.debug("Skipping webhook delivery - user lacks Pro access",
          user_id: user_id,
          event_type: event_type
        )

      {:error, :feature_access_checker_failed} ->
        Logger.warning("Feature access check failed - skipping webhook scheduling",
          user_id: user_id,
          event_type: event_type
        )
    end

    :ok
  end

  # ============================================================================
  # Delivery Logs
  # ============================================================================

  @doc """
  Lists webhook deliveries with pagination.
  """
  @spec list_deliveries(integer(), keyword()) :: [WebhookDeliverySchema.t()]
  def list_deliveries(webhook_id, opts \\ []) do
    WebhookQueries.list_deliveries(webhook_id, opts)
  end

  @doc """
  Gets delivery statistics for a webhook.
  """
  @spec get_delivery_stats(integer(), keyword()) :: %{
          required(:total) => non_neg_integer(),
          required(:successful) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          required(:success_rate) => float(),
          required(:period_days) => non_neg_integer()
        }
  def get_delivery_stats(webhook_id, opts \\ []) do
    WebhookQueries.get_delivery_stats(webhook_id, opts)
  end

  # ============================================================================
  # Events
  # ============================================================================

  @doc """
  Returns all available event types.
  """
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

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end
end
