defmodule Tymeslot.Webhooks do
  @moduledoc """
  Context module for webhook management and delivery.

  Provides the public API for:
  - CRUD operations on webhooks
  - Testing webhook connections
  - Triggering webhook deliveries
  - Viewing delivery logs and statistics
  """

  @behaviour Tymeslot.Notifications.Channel
  @behaviour Tymeslot.Security.EncryptedStorage

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Features
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.Channel
  alias Tymeslot.Notifications.EventOptions
  alias Tymeslot.Security.EncryptedString

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
    do:
      {WebhookSchema.__schema__(:source),
       WebhookSchema.encrypted_credential_fields() ++ EncryptedString.columns(WebhookSchema)}

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

  # The user-facing functions below act on a webhook by its id and the
  # acting user's id, and answer `{:error, :not_found}` for a webhook that
  # user does not own. The delivery worker's system writes
  # (`record_delivery_failure/2`) take the webhook it already loaded.

  @doc "Updates the name, URL, events or token of one of `user_id`'s webhooks."
  @spec update_webhook(integer(), integer(), map()) ::
          {:ok, WebhookSchema.t()}
          | {:error, :not_found | Ecto.Changeset.t() | Features.access_error()}
  def update_webhook(user_id, id, attrs) do
    with_webhook(user_id, id, fn webhook ->
      with :ok <- Features.check_access(user_id, :automations_allowed) do
        WebhookQueries.update_webhook(webhook, attrs)
      end
    end)
  end

  @doc "Deletes one of `user_id`'s webhooks."
  @spec delete_webhook(integer(), integer()) ::
          {:ok, WebhookSchema.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_webhook(user_id, id) do
    with_webhook(user_id, id, &WebhookQueries.delete_webhook/1)
  end

  @doc """
  Pauses or resumes one of `user_id`'s webhooks.

  Re-enabling a webhook that was auto-disabled (i.e. `disabled_at` is set)
  resets the failure bookkeeping (`failure_count`, `disabled_at`,
  `disabled_reason`) along with `is_active`. Otherwise a manual re-enable
  left the counter at the auto-disable threshold, so the very next failed
  delivery immediately disabled the webhook again.
  """
  @spec toggle_webhook(integer(), integer()) ::
          {:ok, WebhookSchema.t()}
          | {:error, :not_found | Ecto.Changeset.t() | Features.access_error()}
  def toggle_webhook(user_id, id) do
    with_webhook(user_id, id, fn webhook ->
      with :ok <- Features.check_access(user_id, :automations_allowed) do
        case webhook do
          %WebhookSchema{is_active: false, disabled_at: %DateTime{}} ->
            WebhookQueries.enable_webhook(webhook)

          webhook ->
            WebhookQueries.toggle_webhook(webhook)
        end
      end
    end)
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

  @doc "Replaces the token of one of `user_id`'s webhooks with a new one."
  @spec regenerate_token(integer(), integer()) ::
          {:ok, WebhookSchema.t()}
          | {:error, :not_found | Ecto.Changeset.t() | Features.access_error()}
  def regenerate_token(user_id, id) do
    with_webhook(user_id, id, fn webhook ->
      with :ok <- Features.check_access(user_id, :automations_allowed) do
        # Passing nil for webhook_token triggers generation in the changeset
        WebhookQueries.update_webhook(webhook, %{webhook_token: nil})
      end
    end)
  end

  defp with_webhook(user_id, id, fun) do
    with {:ok, webhook} <- WebhookQueries.get_webhook(id, user_id), do: fun.(webhook)
  end

  @signature_header "X-Tymeslot-Signature"

  @doc """
  Builds the standard headers for a webhook request whose body is `body`, the
  exact bytes that will be posted.

  With a token, the request carries it in `X-Tymeslot-Token` and is signed in
  `X-Tymeslot-Signature` (see `sign/3`), so a receiver can check that the body
  and timestamp it got are the ones Tymeslot sent. The token header is kept
  for receivers that only compare the token.
  """
  @spec build_headers(binary(), String.t() | nil) :: [{String.t(), String.t()}]
  def build_headers(body, token) when is_binary(body) do
    now = DateTime.utc_now()

    base_headers = [
      {"Content-Type", "application/json"},
      {"User-Agent", "Tymeslot-Webhooks/1.0"},
      {"X-Tymeslot-Timestamp", DateTime.to_iso8601(now)}
    ]

    if token do
      [
        {"X-Tymeslot-Token", token},
        {@signature_header, sign(token, DateTime.to_unix(now), body)}
        | base_headers
      ]
    else
      base_headers
    end
  end

  @doc """
  Returns the `X-Tymeslot-Signature` value for `body` sent at `timestamp`
  (Unix seconds): `t=<timestamp>,v1=<signature>`, where the signature is the
  lowercase hex HMAC-SHA256 of `"<timestamp>.<body>"` keyed with the webhook
  token.

  Binding the timestamp into the signed string lets a receiver reject a
  replayed request by its age as well as a forged or altered body.
  """
  @spec sign(String.t(), integer(), binary()) :: String.t()
  def sign(token, timestamp, body)
      when is_binary(token) and is_integer(timestamp) and is_binary(body) do
    signed = "#{timestamp}.#{body}"
    digest = Base.encode16(:crypto.mac(:hmac, :sha256, token, signed), case: :lower)
    "t=#{timestamp},v1=#{digest}"
  end

  # ============================================================================
  # Validation & Testing
  # ============================================================================

  # Upper bound on the whole test-connection probe (initial request plus every
  # redirect hop), so a target that answers every request with a slow redirect
  # cannot block the calling LiveView process indefinitely.
  @test_connection_deadline_ms 20_000

  @doc """
  Sends one of `user_id`'s webhooks a test payload (see
  `test_webhook_connection/2`). Refused, sending nothing, while the owner's
  plan doesn't include automations.
  """
  @spec test_webhook(integer(), integer()) ::
          :ok | {:error, :not_found | String.t() | Features.access_error()}
  def test_webhook(user_id, id) do
    with_webhook(user_id, id, fn webhook ->
      with :ok <- Features.check_access(user_id, :automations_allowed),
           do: test_webhook_connection(webhook.url, webhook.webhook_token)
    end)
  end

  @doc """
  Tests a webhook connection by sending a test payload.

  The URL is validated once, here, and `HttpDelivery.post/4` is told to skip
  its own initial check (`skip_initial_check: true`) since re-running it on
  the same URL would only double the DNS resolution cost without changing the
  answer. The addresses that check approved are handed on as `:pin_addresses`,
  so the probe connects to one of them rather than resolving the hostname
  again: this path puts a process spawn and a JSON encode between the check and
  the connect, which is the widest DNS-rebinding window in the codebase and the
  reason the addresses must travel with the URL rather than being re-derived.

  Every redirect hop is still independently re-validated by `HttpDelivery` — a
  host that resolves publicly at this check must not be able to 302 the probe
  to a private or loopback address.
  """
  @spec test_webhook_connection(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def test_webhook_connection(url, token \\ nil) do
    with {:ok, addresses} <- SsrfValidator.check_pinned(url) do
      body = Jason.encode!(PayloadBuilder.build_test_payload())
      headers = build_headers(body, token)

      run_bounded_test_connection(url, addresses, body, headers)
    end
  end

  defp run_bounded_test_connection(url, addresses, body, headers) do
    task =
      Tasks.async(Tymeslot.TaskSupervisor, fn ->
        HttpDelivery.post(url, body, headers,
          skip_initial_check: true,
          pin_addresses: addresses
        )
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

  @impl Channel
  def schedule_for_event(user_id, event_type, meeting) do
    user_id
    |> WebhookQueries.list_active_webhooks_for_event(event_type)
    |> Enum.map(&{&1.id, schedule_delivery(&1, event_type, meeting)})
  end

  # The list query does not see the failure threshold, so a webhook that has
  # reached it but is not yet marked disabled is skipped here.
  defp schedule_delivery(webhook, event_type, meeting) do
    if WebhookSchema.should_be_active?(webhook) and
         WebhookSchema.subscribed_to?(webhook, event_type) do
      # The snapshot pins the status and approval fields as they stand *now*, so
      # a retried delivery replays what this event asserted rather than whatever
      # the meeting has become since. Without it a retried `meeting.requested`
      # would report `status: "confirmed"` under a request envelope once the
      # host had answered. Everything not snapshotted (guests, join links) is
      # still read fresh at delivery, which is what you want for those.
      WebhookWorker.schedule_delivery(
        webhook.id,
        event_type,
        meeting.id,
        WebhookWorker.snapshot(meeting),
        SeatView.participant_id(meeting)
      )
    else
      {:error, :integration_not_active}
    end
  end

  # ============================================================================
  # Delivery Logs
  # ============================================================================

  @doc """
  One of `user_id`'s webhooks with its delivery log: the latest deliveries,
  newest first, and the delivery statistics, from a single lookup of the
  webhook.

  Options: `:limit` (deliveries, default 50), `:offset` (default 0) and
  `:days` (the statistics period, default 7).
  """
  @spec delivery_log(integer(), integer(), keyword()) ::
          {:ok,
           %{
             webhook: WebhookSchema.t(),
             deliveries: [WebhookDeliverySchema.t()],
             stats: %{
               required(:total) => non_neg_integer(),
               required(:successful) => non_neg_integer(),
               required(:failed) => non_neg_integer(),
               required(:success_rate) => float(),
               required(:period_days) => non_neg_integer()
             }
           }}
          | {:error, :not_found}
  def delivery_log(user_id, webhook_id, opts \\ []) do
    with_webhook(user_id, webhook_id, fn webhook ->
      {:ok,
       %{
         webhook: WebhookSchema.decrypt_token(webhook),
         deliveries:
           WebhookQueries.list_deliveries(webhook.id, Keyword.take(opts, [:limit, :offset])),
         stats: WebhookQueries.get_delivery_stats(webhook.id, Keyword.take(opts, [:days]))
       }}
    end)
  end

  # ============================================================================
  # Events
  # ============================================================================

  @doc """
  Returns all available event types, with their translated labels; see
  `EventOptions.options/0`.
  """
  @spec available_events() :: [EventOptions.option()]
  defdelegate available_events, to: EventOptions, as: :options

  # ============================================================================
  # Private Helpers
  # ============================================================================
end
