defmodule Tymeslot.Workers.SlackWorker do
  @moduledoc """
  Oban worker for delivering Slack notifications.

  Handles both delivery modes:
    * `oauth` — `chat.postMessage` with the integration's bot token
    * `webhook_url` — POST directly to the user-supplied Incoming Webhook URL

  Errors are mapped to outcomes per the Slack API documentation:
    * `token_revoked` / `account_inactive` / `channel_not_found` → auto-disable
    * rate limiting (HTTP 429 from the Web API or hooks.slack.com, or the
      `ok:false ratelimited` body) → `{:snooze, retry_after}`, without counting
      toward the auto-disable failure budget
    * Anything else → `{:error, reason}` and Oban retries with backoff

  Failures are recorded against the integration only on the genuinely final
  attempt, which is `max_attempts`: a snooze costs the job no attempt, so it
  always gets its full budget of real ones.
  """

  use Oban.Worker,
    queue: :slack_messages,
    max_attempts: 5,
    priority: 2

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Meetings
  alias Tymeslot.Slack
  alias Tymeslot.Slack.{API, MessageBuilder, SlackIntegrationSchema, SlackQueries}

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "integration_id" => integration_id,
            "event_type" => event_type,
            "meeting_id" => meeting_id
          },
          attempt: attempt
        } = job
      ) do
    Logger.metadata(job_id: job.id, attempt: attempt)

    with {:ok, integration} <- SlackQueries.get_integration(integration_id),
         :ok = Logger.metadata(user_id: integration.user_id),
         :ok <- check_feature_access(integration),
         :ok <- check_active(integration),
         {:ok, meeting} <- Meetings.get_meeting(meeting_id) do
      blocks = MessageBuilder.build_blocks(event_type, meeting)
      result = deliver(integration, blocks)
      handle_result(integration, event_type, meeting_id, blocks, job, result)
    else
      {:error, :not_found} -> {:discard, "Integration or meeting not found"}
      {:error, :disabled} -> {:discard, "Integration is disabled"}
      {:error, :insufficient_plan} -> handle_revoked_access(integration_id)
      {:error, :feature_access_checker_failed} -> {:error, :feature_access_checker_failed}
    end
  end

  def perform(%Oban.Job{id: job_id, args: args, attempt: attempt}) do
    Logger.metadata(job_id: job_id, attempt: attempt)

    Logger.error("SlackWorker job missing required parameters",
      arg_keys: Map.keys(args)
    )

    {:discard, "Missing required parameters"}
  end

  @spec schedule_delivery(integer(), String.t(), binary()) :: :ok | {:error, term()}
  def schedule_delivery(integration_id, event_type, meeting_id) do
    result =
      %{
        "integration_id" => integration_id,
        "event_type" => event_type,
        "meeting_id" => meeting_id
      }
      |> new(
        queue: :slack_messages,
        priority: 2,
        unique: [
          period: 300,
          # `:worker` has to stay in the comparison. Slack and Telegram
          # integration ids come from separate sequences and routinely
          # coincide, so on args alone the two channels share one uniqueness
          # namespace and whichever inserts second is silently deduped away.
          fields: [:args, :worker],
          keys: [:integration_id, :event_type, :meeting_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, %Oban.Job{conflict?: true}} -> :ok
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    min(round(:math.pow(2, attempt - 1)), 16)
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp check_feature_access(%SlackIntegrationSchema{} = integration) do
    Features.check_access(integration.user_id, :automations_allowed)
  end

  defp check_active(%SlackIntegrationSchema{} = integration) do
    if SlackIntegrationSchema.status(integration) == :active,
      do: :ok,
      else: {:error, :disabled}
  end

  defp handle_revoked_access(integration_id) do
    case SlackQueries.get_integration(integration_id) do
      {:ok, integration} ->
        case Slack.auto_disable(integration, "Plan no longer permits automations") do
          {:ok, _integration} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to auto-disable Slack integration after plan revocation",
              integration_id: integration_id,
              reason: inspect(reason)
            )
        end

      {:error, _reason} ->
        :ok
    end

    {:discard, "Insufficient plan"}
  end

  defp deliver(%SlackIntegrationSchema{app_mode: "oauth"} = integration, blocks) do
    case Slack.resolve_bot_token(integration) do
      {:ok, token} -> API.post_message_via_token(token, integration.channel_id, blocks)
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver(%SlackIntegrationSchema{app_mode: "webhook_url"} = integration, blocks) do
    case SlackIntegrationSchema.webhook_url(integration) do
      nil -> {:error, :no_webhook_url}
      url -> API.post_message_via_webhook(url, blocks)
    end
  end

  defp handle_result(integration, event_type, meeting_id, blocks, %Oban.Job{} = job, result) do
    delivery_attrs = %{
      integration_id: integration.id,
      event_type: event_type,
      meeting_id: to_string(meeting_id),
      message_blocks: %{"blocks" => blocks},
      attempt_count: job.attempt
    }

    case result do
      {:ok, body} -> handle_success(integration, delivery_attrs, body)
      {:error, reason} -> handle_error(integration, delivery_attrs, job, reason)
    end
  end

  defp handle_success(integration, delivery_attrs, body) do
    persist_success(delivery_attrs, body)
    Slack.record_success(integration)
    :ok
  end

  # Auto-disabling Slack errors — token / account / channel are not retry-worthy.
  @auto_disable_errors ~w(token_revoked account_inactive channel_not_found)

  defp handle_error(integration, delivery_attrs, _job, {:slack_error, err, _body})
       when err in @auto_disable_errors,
       do: auto_disable_and_log(integration, err, delivery_attrs)

  # Rate-limit responses (HTTP 429 from either the Web API or hooks.slack.com,
  # and the `ok:false ratelimited` body) snooze for the requested interval and
  # must never count toward the auto-disable failure budget.
  defp handle_error(_integration, delivery_attrs, _job, {:rate_limited, retry_after}) do
    log_failure(delivery_attrs, "ratelimited", nil)
    {:snooze, retry_after_from(retry_after)}
  end

  defp handle_error(
         _integration,
         delivery_attrs,
         _job,
         {:slack_error, "ratelimited", body, retry_after}
       ) do
    log_failure(delivery_attrs, "ratelimited", body)
    {:snooze, retry_after_from(retry_after)}
  end

  defp handle_error(integration, delivery_attrs, job, {:slack_error, err, body}) do
    log_failure(delivery_attrs, err, body)
    if final_attempt?(job), do: Slack.record_failure(integration, err)
    {:error, err}
  end

  defp handle_error(integration, delivery_attrs, job, {:http_error, status, body}) do
    log_failure(delivery_attrs, "http_#{status}", body)
    if final_attempt?(job), do: Slack.record_failure(integration, "http_#{status}")
    {:error, {:http_error, status}}
  end

  # A 404 from an Incoming Webhook URL means the user revoked the hook in Slack.
  # Retries will never succeed — auto-disable the same way we do for token_revoked.
  defp handle_error(integration, delivery_attrs, _job, {:webhook_error, 404, _body}),
    do: auto_disable_and_log(integration, "webhook_url_revoked", delivery_attrs)

  defp handle_error(integration, delivery_attrs, job, {:webhook_error, status, body}) do
    log_failure(delivery_attrs, "webhook_#{status}", body)
    if final_attempt?(job), do: Slack.record_failure(integration, "webhook_#{status}")
    {:error, {:webhook_error, status}}
  end

  defp handle_error(integration, delivery_attrs, job, {:transport_error, reason}) do
    log_failure(delivery_attrs, "transport_error", reason)
    if final_attempt?(job), do: Slack.record_failure(integration, inspect(reason))
    {:error, :transport_error}
  end

  defp handle_error(integration, delivery_attrs, job, reason) do
    log_failure(delivery_attrs, inspect(reason), nil)
    if final_attempt?(job), do: Slack.record_failure(integration, inspect(reason))
    {:error, reason}
  end

  # A snoozed job comes back without having spent an attempt, so the number to
  # compare against is the job's own `max_attempts` rather than a copy of the
  # `5` above. That records the failure exactly once, on the real last attempt.
  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts}),
    do: attempt >= max_attempts

  defp auto_disable_and_log(integration, reason, delivery_attrs) do
    log_failure(delivery_attrs, reason, nil)
    Slack.auto_disable(integration, reason)
    {:discard, reason}
  end

  defp persist_success(delivery_attrs, body) do
    sanitized = sanitize_body(body)

    attrs =
      Map.merge(delivery_attrs, %{
        response_status: 200,
        response_body: truncate(sanitized, 2000),
        delivered_at: DateTime.utc_now()
      })

    persist_delivery(attrs)
  end

  defp log_failure(delivery_attrs, error, body) do
    sanitized = sanitize_body(body)

    attrs =
      delivery_attrs
      |> Map.put(:error_message, truncate(error, 255))
      |> maybe_put_body(sanitized)

    persist_delivery(attrs)
  end

  defp maybe_put_body(attrs, nil), do: attrs
  defp maybe_put_body(attrs, body), do: Map.put(attrs, :response_body, truncate(body, 2000))

  defp persist_delivery(attrs) do
    case SlackQueries.create_delivery(attrs) do
      {:ok, _delivery} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to create Slack delivery log", error: inspect(reason))
    end
  end

  # ============================================================================
  # Response sanitisation
  #
  # Slack error payloads sometimes echo `access_token` / `token` keys. Strip
  # them before persisting so the delivery log cannot leak credentials.
  # ============================================================================

  defp sanitize_body(nil), do: nil

  defp sanitize_body(body) when is_struct(body), do: inspect(body)

  defp sanitize_body(body) when is_map(body) do
    body
    |> Map.drop(["access_token", "token", :access_token, :token])
    |> Jason.encode!()
  end

  defp sanitize_body(body) when is_binary(body), do: body
  defp sanitize_body(body), do: inspect(body)

  defp retry_after_from(seconds) when is_integer(seconds) and seconds >= 0, do: min(seconds, 600)
  defp retry_after_from(_other), do: 30

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max)
    else
      text
    end
  end

  defp truncate(other, _max), do: inspect(other)
end
