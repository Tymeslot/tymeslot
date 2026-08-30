defmodule Tymeslot.Workers.TelegramWorker do
  @moduledoc """
  Oban worker for delivering Telegram notifications.

  Resolves the bot token at execution time — never from job args.
  Handles Telegram API error codes per REQ-006.
  """

  use Oban.Worker,
    queue: :telegram_messages,
    max_attempts: 5,
    priority: 2

  require Logger

  # `SnoozePolicy` bounds the 429 snooze loop by `attempt`, which — unlike
  # Oban 2.23's (pinned) ever-growing `max_attempts` on snooze — advances by
  # one on every execution regardless of outcome, so it is a reliable budget
  # to snooze against. See
  # deferred/2026-08-29-oban-2-24-snooze-rollback-breaks-attempt-counters.md
  # for how this and the `attempt == 1` "first execution" checks below would
  # need revisiting under Oban 2.24, which is not this deployment's pin.
  @max_rate_limit_snoozes 20
  @min_retry_after_seconds 1
  @max_retry_after_seconds 300

  alias Tymeslot.Features
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Meetings
  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.{API, MessageBuilder, TelegramIntegrationSchema, TelegramQueries}
  alias Tymeslot.Workers.SnoozePolicy

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

    with {:ok, integration} <- TelegramQueries.get_integration(integration_id),
         :ok = Logger.metadata(user_id: integration.user_id),
         :ok <- check_feature_access(integration.user_id),
         :ok <- check_active(integration),
         {:ok, meeting} <- Meetings.get_meeting(meeting_id),
         {:ok, token} <- Telegram.resolve_bot_token(integration) do
      message = MessageBuilder.build_message(event_type, meeting)
      result = send_message(token, integration.chat_id, message)
      handle_result(integration, event_type, meeting_id, message, job, result)
    else
      {:error, :not_found} ->
        {:discard, "Integration or meeting not found"}

      {:error, :disabled} ->
        {:discard, "Integration is disabled"}

      {:error, :insufficient_plan} ->
        {:discard, "Insufficient plan"}

      {:error, :feature_access_checker_failed} ->
        {:error, :feature_access_checker_failed}

      {:error, :no_shared_token} ->
        {:discard, "Shared bot token not configured"}

      {:error, :no_token} ->
        {:discard, "Bot token missing"}
    end
  end

  def perform(%Oban.Job{id: job_id, args: args, attempt: attempt}) do
    Logger.metadata(job_id: job_id, attempt: attempt)

    Logger.error("TelegramWorker job missing required parameters",
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
        queue: :telegram_messages,
        priority: 2,
        unique: [
          period: 300,
          fields: [:args],
          keys: [:integration_id, :event_type, :meeting_id]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} -> :ok
      {:error, %Ecto.Changeset{errors: [unique: _msg]}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    min(round(:math.pow(2, attempt - 1)), 16)
  end

  # Private functions

  defp check_feature_access(user_id) do
    Features.check_access(user_id, :automations_allowed)
  end

  defp check_active(%TelegramIntegrationSchema{} = integration) do
    if TelegramIntegrationSchema.should_be_active?(integration),
      do: :ok,
      else: {:error, :disabled}
  end

  defp send_message(bot_token, chat_id, text) do
    API.send_message(bot_token, chat_id, text)
  end

  defp handle_result(integration, event_type, meeting_id, message, %Oban.Job{} = job, result) do
    log_delivery(integration, event_type, meeting_id, message, job.attempt, result)
    handle_api_result(integration, job, result)
  end

  defp log_delivery(integration, event_type, meeting_id, message, attempt, result) do
    delivery_attrs = %{
      integration_id: integration.id,
      event_type: event_type,
      meeting_id: meeting_id,
      message_text: truncate(message, 4096),
      attempt_count: attempt
    }

    delivery_attrs =
      case result do
        {:ok, status, body} ->
          Map.merge(delivery_attrs, %{
            response_status: status,
            response_body: truncate(body, 2000),
            delivered_at: DateTime.utc_now()
          })

        {:error, error_msg} ->
          Map.put(delivery_attrs, :error_message, truncate(error_msg, 255))
      end

    case TelegramQueries.create_delivery(delivery_attrs) do
      {:ok, _delivery} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to create Telegram delivery log", error: inspect(reason))
    end
  end

  defp handle_api_result(integration, %Oban.Job{attempt: attempt} = job, result) do
    case result do
      {:ok, status, _body} when status >= 200 and status < 300 ->
        Telegram.record_success(integration)
        :ok

      {:ok, 401, _body} ->
        handle_unauthorized(integration)

      # Telegram answers both "bot was blocked by the user" and "bot was kicked"
      # with 403, deriving the body's `Forbidden:` prefix from that same code.
      # 400 stays matched too: the description is the reliable signal, and an
      # intermediary can rewrite the transport status.
      {:ok, status, body} when status in [400, 403] ->
        handle_rejection(integration, body, attempt)

      {:ok, 429, body} ->
        handle_rate_limit(integration, job, body)

      {:ok, status, _body} ->
        if attempt == 1, do: Telegram.record_failure(integration, "HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        if attempt == 1, do: Telegram.record_failure(integration, to_string(reason))
        {:error, reason}
    end
  end

  # A 401 means the bot token itself was rejected. In "own" mode that token
  # belongs to this integration alone, so it is safe to treat as a permanent,
  # per-integration failure. In "shared" mode the same token is used by every
  # user on the deployment, so a 401 is the operator's shared credential
  # having been rotated or revoked, not a fault of this integration: disabling
  # it would silently disable Telegram for the whole deployment, one
  # integration at a time, requiring a manual per-user re-enable. Surface it
  # to the operator instead and leave the integration active.
  defp handle_unauthorized(%TelegramIntegrationSchema{bot_mode: "own"} = integration) do
    auto_disable(integration, "invalid_token")
    {:discard, "Unauthorized"}
  end

  # Always reported, regardless of which attempt this is: this path always
  # discards, so nothing else will raise this alert for this job, and
  # `AdminAlerts` already deduplicates repeat alerts for 24h. A job that spent
  # its first attempt on an unrelated transient failure and only reaches the
  # shared token on attempt 2+ must not lose its alert.
  defp handle_unauthorized(%TelegramIntegrationSchema{bot_mode: "shared"} = integration) do
    Logger.warning("Shared Telegram bot token rejected (401 Unauthorized)",
      integration_id: integration.id
    )

    AdminAlerts.report(:integration_health_failure,
      summary: "Shared Telegram bot token rejected (401 Unauthorized)",
      context: %{integration_id: integration.id, bot_mode: "shared"}
    )

    {:discard, "Unauthorized"}
  end

  defp auto_disable(integration, reason) do
    case Telegram.auto_disable(integration, reason) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to auto-disable Telegram integration",
          integration_id: integration.id,
          reason: inspect(changeset)
        )
    end
  end

  defp handle_rejection(integration, body, attempt) do
    description = extract_error_description(body)

    cond do
      String.contains?(description, "bot was blocked by the user") ->
        auto_disable(integration, "bot_blocked")
        {:discard, "Bot blocked"}

      String.contains?(description, "bot was kicked") ->
        auto_disable(integration, "bot_kicked")
        {:discard, "Bot kicked"}

      migrate_to_chat_id = extract_migrate_to_chat_id(body) ->
        migrate_chat_id(integration, migrate_to_chat_id)

      permanently_unreachable?(description) ->
        auto_disable(integration, "chat_unreachable")
        {:discard, "Chat unreachable"}

      true ->
        if attempt == 1,
          do: Telegram.record_failure(integration, "Bad Request: #{description}")

        {:error, {:bad_request, description}}
    end
  end

  # Telegram's other permanent per-chat rejections: the chat/user was deleted,
  # the user deactivated their account, or the bot has never been messaged
  # first by the user (so it cannot open the conversation). None of these are
  # retry-worthy — every future event for this chat would fail the same way.
  defp permanently_unreachable?(description) do
    String.contains?(description, "chat not found") or
      String.contains?(description, "user is deactivated") or
      String.contains?(description, "bot can't initiate conversation with a user")
  end

  # A group upgrading to a supergroup gets a new chat id; the old one is dead
  # forever, but the new one is recoverable and Telegram hands it to us
  # directly. Persist it and let Oban retry — the next attempt re-reads the
  # integration and sends to the corrected chat id.
  defp migrate_chat_id(integration, new_chat_id) do
    case Telegram.migrate_chat_id(integration, to_string(new_chat_id)) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to migrate Telegram chat id after supergroup upgrade",
          integration_id: integration.id,
          reason: inspect(reason)
        )
    end

    {:error, {:chat_migrated, new_chat_id}}
  end

  defp handle_rate_limit(integration, %Oban.Job{attempt: attempt}, body) do
    retry_after = body |> extract_retry_after() |> clamp_retry_after()

    case SnoozePolicy.snooze_or_exhaust(attempt,
           max_snoozes: @max_rate_limit_snoozes,
           base_seconds: retry_after
         ) do
      {:snooze, seconds} ->
        {:snooze, seconds}

      :exhausted ->
        Telegram.record_failure(integration, "rate_limited")
        {:discard, "Rate limited too many times"}
    end
  end

  defp extract_retry_after(body) do
    case Jason.decode(body) do
      {:ok, %{"parameters" => %{"retry_after" => seconds}}} -> seconds
      _other -> 30
    end
  end

  defp clamp_retry_after(seconds) when is_integer(seconds) do
    seconds
    |> max(@min_retry_after_seconds)
    |> min(@max_retry_after_seconds)
  end

  defp clamp_retry_after(_other), do: 30

  defp extract_error_description(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"description" => desc}} -> desc
      _result -> body
    end
  end

  defp extract_migrate_to_chat_id(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"parameters" => %{"migrate_to_chat_id" => new_chat_id}}} -> new_chat_id
      _other -> nil
    end
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max)
    else
      text
    end
  end
end
