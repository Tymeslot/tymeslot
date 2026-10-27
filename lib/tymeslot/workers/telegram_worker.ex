defmodule Tymeslot.Workers.TelegramWorker do
  @moduledoc """
  Oban worker for delivering Telegram notifications.

  Resolves the bot token at execution time — never from job args.
  Handles Telegram API error codes per REQ-006.

  A delivery failure is counted against the integration once per job, on
  its final attempt, and a plan that no longer covers automations switches
  the integration off.

  The send is claimed through `Tymeslot.Workers.DeliveryClaims` before it is
  made, so a job the Oban lifeline rescues after the message reached Telegram
  does not send it to the chat a second time. Only a successful send keeps
  the claim; every retry, snooze and discard path releases it.
  """

  use Oban.Worker,
    queue: :telegram_messages,
    max_attempts: 5,
    priority: 2

  require Logger

  # The 429 snooze loop is bounded with `SnoozePolicy.executions/1` rather
  # than `job.attempt`: from Oban 2.24 a snooze rolls `attempt` back, so
  # `attempt` never climbs far enough to bound it. The same rollback is what
  # lets failures be counted on the final attempt
  # (`MeetingNotificationJob.final_attempt?/1`): a snooze never spends one.
  @max_rate_limit_snoozes 20
  @min_retry_after_seconds 1
  @max_retry_after_seconds 300

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Notifications.Recipients
  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.{API, MessageBuilder, TelegramIntegrationSchema, TelegramQueries}
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.MeetingNotificationJob
  alias Tymeslot.Workers.SnoozePolicy

  @behaviour ExpectedJobOutcome

  # The work no longer applies, or only the user can fix their bot or chat. A
  # rejected shared bot token raises its own alert. Missing parameters, a
  # missing shared token and endless rate limiting are recorded.
  @gone "Integration or meeting not found"
  @disabled "Integration is disabled"
  @insufficient_plan "Insufficient plan"
  @feature_disabled "Automations are switched off"
  @token_missing "Bot token missing"
  @unauthorized "Unauthorized"
  @bot_blocked "Bot blocked"
  @bot_kicked "Bot kicked"
  @chat_unreachable "Chat unreachable"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [
        @gone,
        @disabled,
        @insufficient_plan,
        @feature_disabled,
        @token_missing,
        @unauthorized,
        @bot_blocked,
        @bot_kicked,
        @chat_unreachable
      ]

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args:
            %{
              "integration_id" => integration_id,
              "event_type" => event_type,
              "meeting_id" => meeting_id
            } = args,
          attempt: attempt
        } = job
      ) do
    Logger.metadata(job_id: job.id, attempt: attempt)

    with {:ok, integration} <- TelegramQueries.get_integration(integration_id),
         :ok = ErrorTracking.put_context(user_id: integration.user_id),
         :ok <- MeetingNotificationJob.feature_gate(integration.user_id),
         :ok <- check_active(integration),
         {:ok, meeting} <- MeetingNotificationJob.load_meeting(meeting_id, args["participant_id"]),
         {:ok, token} <- Telegram.resolve_bot_token(integration) do
      timezone = Recipients.get_organizer_timezone(meeting)
      message = MessageBuilder.build_message(event_type, meeting, timezone)

      DeliveryClaims.once(job, "telegram_message", fn ->
        result = send_message(token, integration.chat_id, message)
        handle_result(integration, event_type, meeting_id, message, job, result)
      end)
    else
      refusal -> refuse(refusal, integration_id)
    end
  end

  def perform(%Oban.Job{id: job_id, args: args, attempt: attempt}) do
    Logger.metadata(job_id: job_id, attempt: attempt)

    Logger.error("TelegramWorker job missing required parameters",
      arg_keys: Map.keys(args)
    )

    {:discard, "Missing required parameters"}
  end

  # Why a job did not reach the API, as Oban's answer for it.
  defp refuse({:error, :not_found}, _integration_id), do: {:discard, @gone}
  defp refuse({:error, :disabled}, _integration_id), do: {:discard, @disabled}
  defp refuse({:revoked, _reason}, _integration_id), do: {:discard, @insufficient_plan}
  defp refuse({:discard, :feature_disabled}, _integration_id), do: {:discard, @feature_disabled}
  defp refuse({:error, :feature_access_checker_failed} = error, _integration_id), do: error

  defp refuse({:error, :no_shared_token}, _integration_id),
    do: {:discard, "Shared bot token not configured"}

  defp refuse({:error, :no_token}, _integration_id), do: {:discard, @token_missing}

  @doc """
  Schedules a message for a meeting event.

  `participant_id` names the seat of a group meeting the event is about (see
  `Tymeslot.Meetings.SeatView`); the message then names that seat's
  participant. Each seat is its own message, so it is part of the uniqueness
  key; a solo meeting passes `nil`, which is stored and keyed as well, so a
  seat's message and the meeting's own are never taken for duplicates (see
  `Tymeslot.Workers.MeetingNotificationJob.schedule/5`).
  """
  @spec schedule_delivery(integer(), String.t(), binary(), binary() | nil) ::
          :ok | {:error, term()}
  def schedule_delivery(integration_id, event_type, meeting_id, participant_id \\ nil) do
    MeetingNotificationJob.schedule(
      __MODULE__,
      %{
        "integration_id" => integration_id,
        "event_type" => event_type,
        "meeting_id" => meeting_id
      },
      participant_id,
      [:integration_id, :event_type, :meeting_id],
      queue: :telegram_messages
    )
  end

  @impl Oban.Worker
  defdelegate backoff(job), to: MeetingNotificationJob, as: :chat_backoff

  # Private functions

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
        Logger.warning("Failed to create Telegram delivery log", error: LogFormat.reason(reason))
    end
  end

  defp handle_api_result(integration, %Oban.Job{} = job, result) do
    final_attempt? = MeetingNotificationJob.final_attempt?(job)

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
        handle_rejection(integration, body, final_attempt?)

      {:ok, 429, body} ->
        handle_rate_limit(integration, job, body)

      {:ok, status, _body} ->
        if final_attempt?, do: Telegram.record_failure(integration, "HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        if final_attempt?, do: Telegram.record_failure(integration, to_string(reason))
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
    {:discard, @unauthorized}
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

    {:discard, @unauthorized}
  end

  defp auto_disable(integration, reason) do
    case Telegram.auto_disable(integration, reason) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to auto-disable Telegram integration",
          integration_id: integration.id,
          reason: LogFormat.reason(changeset)
        )
    end
  end

  defp handle_rejection(integration, body, final_attempt?) do
    description = extract_error_description(body)

    cond do
      String.contains?(description, "bot was blocked by the user") ->
        auto_disable(integration, "bot_blocked")
        {:discard, @bot_blocked}

      String.contains?(description, "bot was kicked") ->
        auto_disable(integration, "bot_kicked")
        {:discard, @bot_kicked}

      migrate_to_chat_id = extract_migrate_to_chat_id(body) ->
        migrate_chat_id(integration, migrate_to_chat_id)

      permanently_unreachable?(description) ->
        auto_disable(integration, "chat_unreachable")
        {:discard, @chat_unreachable}

      true ->
        if final_attempt?,
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
          reason: LogFormat.reason(reason)
        )
    end

    {:error, {:chat_migrated, new_chat_id}}
  end

  defp handle_rate_limit(integration, %Oban.Job{} = job, body) do
    retry_after = body |> extract_retry_after() |> clamp_retry_after()

    case SnoozePolicy.snooze_or_exhaust(SnoozePolicy.executions(job),
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
