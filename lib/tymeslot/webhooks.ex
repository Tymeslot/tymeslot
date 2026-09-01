defmodule Tymeslot.Webhooks do
  @moduledoc """
  Context module for webhook management and delivery.

  Provides the public API for:
  - CRUD operations on webhooks
  - Testing webhook connections
  - Triggering webhook deliveries
  - Viewing delivery logs and statistics
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Notifications.EventTypes

  alias Tymeslot.Webhooks.{
    HttpDelivery,
    PayloadBuilder,
    SsrfValidator,
    WebhookDeliverySchema,
    WebhookQueries,
    WebhookSchema
  }

  alias Tymeslot.Workers.WebhookWorker

  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage,
    do: {WebhookSchema.__schema__(:source), WebhookSchema.encrypted_credential_fields()}

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
          | {:error, Ecto.Changeset.t() | Features.access_error()}
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
          | {:error, Ecto.Changeset.t() | Features.access_error()}
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

  Re-enabling a webhook that was auto-disabled (i.e. `disabled_at` is set)
  goes through `enable_webhook/1` instead of a bare flip, so the failure
  bookkeeping (`failure_count`, `disabled_at`, `disabled_reason`) is reset
  along with `is_active`. Otherwise a manual re-enable left the counter at
  the auto-disable threshold, so the very next failed delivery immediately
  disabled the webhook again.
  """
  @spec toggle_webhook(WebhookSchema.t()) ::
          {:ok, WebhookSchema.t()}
          | {:error, Ecto.Changeset.t() | Features.access_error()}
  def toggle_webhook(%WebhookSchema{is_active: false, disabled_at: %DateTime{}} = webhook) do
    enable_webhook(webhook)
  end

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
      if updated.failure_count >= WebhookSchema.max_failure_count() do
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
          | {:error, Ecto.Changeset.t() | Features.access_error()}
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
          | {:error, Ecto.Changeset.t() | Features.access_error()}
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

  # Upper bound on the whole test-connection probe (initial request plus every
  # redirect hop), so a target that answers every request with a slow redirect
  # cannot block the calling LiveView process indefinitely.
  @test_connection_deadline_ms 20_000

  @doc """
  Tests a webhook connection by sending a test payload.

  The URL is validated once, here, and `HttpDelivery.post/4` is told to skip
  its own initial check (`skip_initial_check: true`) since re-running it on
  the same URL would only double the DNS resolution cost without changing the
  answer. Every redirect hop is still independently re-validated by
  `HttpDelivery` — a host that resolves publicly at this check must not be
  able to 302 the probe to a private or loopback address.
  """
  @spec test_webhook_connection(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def test_webhook_connection(url, token \\ nil) do
    with :ok <- SsrfValidator.check(url) do
      payload = PayloadBuilder.build_test_payload()
      headers = build_headers(payload, token)

      run_bounded_test_connection(url, payload, headers)
    end
  end

  defp run_bounded_test_connection(url, payload, headers) do
    task =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        HttpDelivery.post(url, Jason.encode!(payload), headers, skip_initial_check: true)
      end)

    case Task.yield(task, @test_connection_deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        map_test_connection_result(result)

      nil ->
        {:error, dgettext("dashboard_automation", "The connection test took too long to respond")}
    end
  end

  defp map_test_connection_result({:ok, status, _body}) when status >= 200 and status < 300,
    do: :ok

  defp map_test_connection_result({:ok, status, _body}) do
    {:error,
     dgettext("dashboard_automation", "Webhook returned status %{status}", status: status)}
  end

  defp map_test_connection_result({:error, :blocked_by_ssrf}) do
    {:error, dgettext("dashboard_automation", "URL resolves to a private or restricted address")}
  end

  defp map_test_connection_result({:error, :blocked_redirect}) do
    {:error,
     dgettext(
       "dashboard_automation",
       "The webhook redirected to a private or restricted address"
     )}
  end

  defp map_test_connection_result({:error, :too_many_redirects}) do
    {:error, dgettext("dashboard_automation", "The webhook redirected too many times")}
  end

  defp map_test_connection_result({:error, :redirect_missing_location}) do
    {:error,
     dgettext("dashboard_automation", "The webhook redirected without a destination address")}
  end

  defp map_test_connection_result({:error, _reason}) do
    {:error, dgettext("dashboard_automation", "Connection failed")}
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

  Derived from `EventTypes.all/0` rather than restated here, so a webhook
  cannot silently gain an event it has no way to be subscribed to — that
  restatement is exactly how `meeting.requested`, `meeting.declined` and
  `meeting.request_expired` went live undispatchable in the first place.
  """
  @spec available_events() :: [
          %{
            required(:value) => String.t(),
            required(:label) => String.t(),
            required(:description) => String.t()
          }
        ]
  def available_events do
    Enum.map(EventTypes.all(), fn value ->
      %{value: value, label: event_label(value), description: event_description(value)}
    end)
  end

  defp event_label("meeting.created"), do: dgettext("dashboard_automation", "Meeting Created")
  defp event_label("meeting.requested"), do: dgettext("dashboard_automation", "Booking Requested")
  defp event_label("meeting.declined"), do: dgettext("dashboard_automation", "Booking Declined")

  defp event_label("meeting.request_expired"),
    do: dgettext("dashboard_automation", "Booking Request Expired")

  defp event_label("meeting.cancelled"), do: dgettext("dashboard_automation", "Meeting Cancelled")

  defp event_label("meeting.rescheduled"),
    do: dgettext("dashboard_automation", "Meeting Rescheduled")

  defp event_description("meeting.created"),
    do: dgettext("dashboard_automation", "Triggers when a new booking is successfully created")

  defp event_description("meeting.requested"),
    do:
      dgettext(
        "dashboard_automation",
        "Triggers when someone requests a booking on a meeting type that needs your approval"
      )

  defp event_description("meeting.declined"),
    do: dgettext("dashboard_automation", "Triggers when you decline a booking request")

  defp event_description("meeting.request_expired"),
    do:
      dgettext(
        "dashboard_automation",
        "Triggers when nobody answers a booking request before its deadline"
      )

  defp event_description("meeting.cancelled"),
    do: dgettext("dashboard_automation", "Triggers when an existing booking is cancelled")

  defp event_description("meeting.rescheduled"),
    do: dgettext("dashboard_automation", "Triggers when a booking time is changed")

  # ============================================================================
  # Private Helpers
  # ============================================================================
end
