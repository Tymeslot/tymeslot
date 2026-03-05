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

  alias Tymeslot.DatabaseQueries.{MeetingQueries, TelegramQueries}
  alias Tymeslot.DatabaseSchemas.TelegramIntegrationSchema
  alias Tymeslot.Features
  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.{API, MessageBuilder}

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
         {:ok, meeting} <- MeetingQueries.get_meeting(meeting_id),
         {:ok, token} <- Telegram.resolve_bot_token(integration) do
      message = MessageBuilder.build_message(event_type, meeting)
      result = send_message(token, integration.chat_id, message)
      handle_result(integration, event_type, meeting_id, message, attempt, result)
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

  defp handle_result(integration, event_type, meeting_id, message, attempt, result) do
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
          Map.put(delivery_attrs, :error_message, truncate(error_msg, 2000))
      end

    TelegramQueries.create_delivery(delivery_attrs)

    case result do
      {:ok, status, _body} when status >= 200 and status < 300 ->
        TelegramQueries.record_success(integration)
        :ok

      {:ok, 401, _body} ->
        auto_disable(integration, "Unauthorized (invalid bot token)")
        {:discard, "Unauthorized"}

      {:ok, 400, body} ->
        handle_400_error(integration, body, attempt)

      {:ok, 429, body} ->
        handle_rate_limit(body)

      {:ok, status, _body} ->
        if attempt == 1, do: TelegramQueries.record_failure(integration, "HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        if attempt == 1, do: TelegramQueries.record_failure(integration, to_string(reason))
        {:error, reason}
    end
  end

  defp handle_400_error(integration, body, attempt) do
    description = extract_error_description(body)

    cond do
      String.contains?(description, "bot was blocked by the user") ->
        auto_disable(integration, "Bot was blocked by the user")
        {:discard, "Bot blocked"}

      String.contains?(description, "bot was kicked") ->
        auto_disable(integration, "Bot was kicked from the group")
        {:discard, "Bot kicked"}

      true ->
        if attempt == 1,
          do: TelegramQueries.record_failure(integration, "Bad Request: #{description}")

        {:error, {:bad_request, description}}
    end
  end

  defp handle_rate_limit(body) do
    retry_after =
      case Jason.decode(body) do
        {:ok, %{"parameters" => %{"retry_after" => seconds}}} -> seconds
        _other -> 30
      end

    {:snooze, retry_after}
  end

  defp auto_disable(integration, reason) do
    TelegramQueries.update_integration(integration, %{
      is_active: false,
      disabled_at: DateTime.utc_now(),
      disabled_reason: reason
    })
  end

  defp extract_error_description(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"description" => desc}} -> desc
      _result -> body
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
