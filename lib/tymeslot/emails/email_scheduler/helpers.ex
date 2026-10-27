defmodule Tymeslot.Emails.EmailScheduler.Helpers do
  @moduledoc "Shared helpers for EmailScheduler sub-modules."

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @doc """
  Formats an Oban insert error into a loggable string.
  """
  @spec format_insert_error(term()) :: term()
  def format_insert_error(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  def format_insert_error(other), do: LogFormat.reason(other)

  @doc """
  Inserts an email job and logs the outcome under the job's action, the one
  insert every scheduler goes through.

  A unique conflict is not a failure: the job wanted already exists, and is
  reported as `{:ok, :duplicate}`. Oban signals it by returning the existing
  job with `conflict?: true`; a unique constraint never reaches the
  changeset, because Oban resolves it with an upsert, so an
  `{:error, %Ecto.Changeset{errors: [unique: _]}}` clause would be
  unreachable and would misreport a duplicate as a fresh schedule.

  `metadata` is added to each log line (the meeting, the recipient, the
  scheduled time). A failure is returned as Oban gave it.

  `quiet_duplicates: true` logs a duplicate at debug level, for a scheduler
  whose callers re-raise the same email in a loop (admin alerts) and would
  otherwise log one line per cycle for an email that is not being sent.
  """
  @spec insert(Changeset.t(), keyword(), keyword()) ::
          {:ok, :scheduled | :duplicate} | {:error, term()}
  def insert(%Changeset{} = changeset, metadata \\ [], opts \\ []) do
    metadata = [action: action(changeset)] ++ metadata

    case Oban.insert(changeset) do
      {:ok, %Oban.Job{conflict?: true}} ->
        level = if Keyword.get(opts, :quiet_duplicates, false), do: :debug, else: :info
        Logger.log(level, "Email job already queued, not scheduling it twice", metadata)
        {:ok, :duplicate}

      {:ok, _job} ->
        Logger.info("Email job scheduled", metadata)
        {:ok, :scheduled}

      {:error, reason} = error ->
        Logger.error(
          "Failed to schedule email job",
          [error: format_insert_error(reason)] ++ metadata
        )

        error
    end
  end

  @doc """
  `insert/2`'s result for a scheduler whose contract is `:ok | {:error, _}`:
  a duplicate is as good as a fresh schedule.
  """
  @spec ok({:ok, :scheduled | :duplicate} | {:error, term()}) :: :ok | {:error, term()}
  def ok({:ok, _scheduled_or_duplicate}), do: :ok
  def ok({:error, _reason} = error), do: error

  defp action(changeset) do
    case Changeset.get_field(changeset, :args) do
      %{"action" => action} -> action
      _args -> nil
    end
  end
end
