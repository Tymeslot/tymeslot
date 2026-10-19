defmodule Tymeslot.Workers.AccountFilesPurgeWorker do
  @moduledoc """
  Removes a deleted profile's uploaded avatars and theme backgrounds from
  disk, retrying when the first attempt, made inline by
  `Tymeslot.Auth.AccountDeletion`, could not.

  The account is already gone by then, so a file left behind is personal data
  kept past an erasure request with nothing pointing at it. A transient
  failure (a busy volume, a permission fixed by hand) gets several more
  attempts with Oban's backoff; once they are spent, the operator is alerted
  with the paths to remove by hand.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:profile_id], states: :incomplete]

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  @type failure :: %{files: :avatars | :theme_backgrounds, reason: term(), path: Path.t()}

  @doc """
  Removes the profile's upload directories. Returns the directories that could
  not be removed, with why.
  """
  @spec purge(pos_integer()) :: :ok | {:error, [failure()]}
  def purge(profile_id) do
    failures =
      for {files, outcome} <- [
            avatars: Profiles.delete_avatar_files(profile_id),
            theme_backgrounds: ThemeCustomizations.delete_profile_files(profile_id)
          ],
          outcome != :ok do
        {:error, reason, path} = outcome
        %{files: files, reason: reason, path: path}
      end

    if failures == [], do: :ok, else: {:error, failures}
  end

  @doc """
  Queues another attempt at `purge/1` for a deleted profile. A database
  failure is returned rather than raised: the account is already deleted, and
  the caller alerts the operator instead.
  """
  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(profile_id) do
    %{profile_id: profile_id} |> new() |> Oban.insert()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}} = job) do
    case purge(profile_id) do
      :ok ->
        :ok

      {:error, failures} when job.attempt >= job.max_attempts ->
        report(profile_id, failures)
        {:cancel, "Uploaded files of a deleted account could not be removed"}

      {:error, failures} ->
        {:error, Enum.map(failures, &Map.take(&1, [:files, :reason]))}
    end
  end

  @doc """
  Tells the operator that a deleted profile's files are still on disk and
  where, for when no further attempt will be made.
  """
  @spec report(pos_integer(), [failure()]) :: :ok | {:error, term()}
  def report(profile_id, failures) do
    Logger.error("Uploaded files of a deleted account could not be removed",
      profile_id: profile_id,
      paths: Enum.map(failures, & &1.path),
      reason: LogFormat.reason(hd(failures).reason)
    )

    AdminAlerts.report(:account_files_delete_failed,
      summary: "A deleted account's uploaded files are still on disk; remove them by hand",
      reason: hd(failures).reason,
      context: %{profile_id: profile_id, paths: Enum.map_join(failures, ", ", & &1.path)}
    )
  end
end
