defmodule Tymeslot.Workers.EmailWorker do
  @moduledoc """
  Oban worker for executing email sending jobs with intelligent retry and error handling.

  This worker executes email jobs enqueued by `Tymeslot.Emails.EmailScheduler`.
  It handles:
  - Sending confirmation emails after meeting creation
  - Sending reminder emails before meetings
  - Smart retry logic with exponential backoff
  - Error categorisation for appropriate handling
  - Timeouts for external service calls

  To schedule email jobs, use `Tymeslot.Emails.EmailScheduler` — do not call
  `new/2` directly from application code.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    # Higher priority (0-3, lower number = higher priority)
    priority: 1

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Workers.EmailWorkerHandlers
  alias Tymeslot.Workers.TransactionalEmailDelivery
  require Logger

  # Configuration
  # 30 seconds — overridable via config (e.g. lowered in tests)
  @default_email_timeout_ms 30_000
  # 1 second base for exponential backoff
  @backoff_base_ms 1_000

  @doc """
  Performs the email job based on the action specified in the args.
  Implements exponential backoff for retries.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => action} = args, attempt: attempt} = job) do
    Logger.metadata(job_id: job.id, attempt: attempt)
    if user_id = args["user_id"], do: Logger.metadata(user_id: user_id)

    execute_email_job_with_timeout(action, args, job)
  end

  def perform(%Oban.Job{args: args, attempt: attempt} = job) do
    Logger.metadata(job_id: job.id, attempt: attempt)

    Logger.error("EmailWorker job missing action parameter",
      arg_keys: Map.keys(args)
    )

    {:discard, "Missing action parameter"}
  end

  # Private functions

  defp handle_result(result, job) do
    case result do
      :ok ->
        :ok

      {:error, error_type} ->
        handle_email_error(error_type, job)

      {:discard, reason} ->
        {:discard, reason}

      _other ->
        handle_unexpected_email_result(result)
    end
  end

  # `:rate_limited`, `:circuit_open`, and `{:recipient_rejected, _}` all mean
  # something other than an ordinary retry, and mean the same thing for every
  # email job — the policy for them lives once in `TransactionalEmailDelivery`
  # and is shared with the Stripe-triggered workers that deliver outside this
  # worker entirely. `failure_message` is unused by those three cases.
  defp handle_email_error(:rate_limited, %{attempt: attempt}) do
    TransactionalEmailDelivery.handle_failure(:rate_limited, "", attempt: attempt)
  end

  defp handle_email_error(:circuit_open, %{attempt: attempt}) do
    TransactionalEmailDelivery.handle_failure(:circuit_open, "", attempt: attempt)
  end

  defp handle_email_error({:recipient_rejected, reason}, %{args: args}) do
    TransactionalEmailDelivery.handle_failure({:recipient_rejected, reason}, "",
      action: args["action"],
      meeting_id: args["meeting_id"]
    )
  end

  defp handle_email_error(:invalid_email, _job) do
    Logger.error("Invalid email address, discarding job")
    {:discard, "Invalid email address"}
  end

  defp handle_email_error(:meeting_not_found, _job) do
    Logger.error("Meeting not found, discarding job")
    {:discard, "Meeting not found"}
  end

  defp handle_email_error(:meeting_cancelled, _job) do
    Logger.info("Meeting cancelled, discarding job")
    {:discard, "Meeting cancelled"}
  end

  defp handle_email_error(reason, _job) when is_binary(reason) do
    # Generic error - retry with backoff
    {:error, reason}
  end

  defp handle_email_error(_other_reason, _job) do
    # Unknown error format - retry
    {:error, "Unknown error"}
  end

  defp handle_unexpected_email_result(result) do
    Logger.error("Unexpected result from email job", result: result)
    {:error, "Unexpected result"}
  end

  defp execute_email_job_with_timeout(action, args, job) do
    timeout_ms = email_timeout_ms()

    task =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        EmailWorkerHandlers.execute_email_action(action, args)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, result} ->
        handle_result(result, job)

      nil ->
        # A hard timeout is ambiguous — the message may already be on the wire.
        # Discard rather than letting Oban retry, which would re-send a possibly
        # delivered email. A genuinely lost mail can be re-requested by the user.
        Logger.warning("Email job timed out; discarding to avoid duplicate sends",
          action: action,
          timeout_ms: timeout_ms,
          job_id: job.id,
          attempt: job.attempt
        )

        {:discard, "Email sending timed out"}
    end
  end

  defp email_timeout_ms do
    Application.get_env(:tymeslot, :email_timeout_ms, @default_email_timeout_ms)
  end

  defp calculate_backoff(attempt) do
    # Exponential backoff: 1s, 2s, 4s, 8s, 16s
    round(min(@backoff_base_ms * :math.pow(2, attempt - 1), 16_000))
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # convert ms to seconds for Oban backoff
    div(calculate_backoff(attempt), 1_000)
  end

  # Validate required fields based on action; delegates to EmailScheduler
  # which owns the field definitions alongside the scheduling functions.
  @spec changeset(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  def changeset(changeset, args), do: EmailScheduler.validate_args(changeset, args)
end
