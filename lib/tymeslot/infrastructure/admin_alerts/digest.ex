defmodule Tymeslot.Infrastructure.AdminAlerts.Digest do
  @moduledoc """
  Collects info-severity admin alerts for one daily email instead of one
  email each.

  `EmailNotifier` records an info alert here in place of enqueuing its email,
  under the same gates: admin alerts switched on, a valid recipient, and not
  an alert about the email pipeline itself. The alert is still logged at once.

  ## Deduplication

  An entry is keyed on the alert's dedup hash, the one `AdminAlertScheduler`
  uses for an immediate alert email. A repeat while the entry waits raises
  its count rather than adding a row, so each distinct alert appears once per
  digest, with how often it happened. A repeat after the digest went out
  starts a fresh entry for the next one: at most one mention per key a day,
  like the immediate emails' 24-hour window.

  ## Delivery and bounds

  `deliver/0` (run daily by `Tymeslot.Workers.AdminAlertDigestWorker`) takes
  every waiting entry and hands one digest email to
  `Tymeslot.Workers.EmailWorker` in a single transaction: the entries are
  deleted only when the email job is inserted, and a failed insert rolls the
  delete back. From there the email retries on the admin alert schedule, with
  the entries in its args, so a mail outage never grows the table. One email
  lists at most 100 entries, the oldest; the rest are counted by type and
  dropped with them, so every run empties the table however many arrived.
  """

  require Logger

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.DigestEntryQueries
  alias Tymeslot.Infrastructure.AdminAlerts.EmailNotifier
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker.AdminAlertScheduler

  @max_entries 100

  @doc """
  Records an info alert for the next digest. `metadata` must already be
  scrubbed; `dedup_key` is the alert's `AlertTypes.dedup_key/2`, built from
  the raw metadata and stored only as a hash.
  """
  @spec record(atom(), String.t(), String.t(), map(), String.t()) :: :ok | {:error, term()}
  def record(type, category, message, metadata, dedup_key) do
    attrs = %{
      alert_type: to_string(type),
      category: category,
      message: message,
      metadata: AdminAlertScheduler.serialize_metadata(metadata),
      alert_hash: AdminAlertScheduler.alert_hash(category, dedup_key)
    }

    case DigestEntryQueries.upsert(attrs) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to record admin alert for the digest",
          category: category,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Hands every waiting entry to the email worker as one digest email.

  Sends nothing when no entry waits. With admin alerts switched off, drops
  the waiting entries: they were recorded while alerts were on and would
  otherwise be mailed, stale, whenever alerts come back. With no valid
  recipient, keeps them (none are recorded meanwhile) and logs the missing
  recipient.
  """
  @spec deliver() :: :ok | {:error, term()}
  def deliver do
    recipient = AdminAlerts.recipient()

    cond do
      not AdminAlerts.enabled?() -> drop_waiting()
      not AdminAlerts.valid_email?(recipient) -> AdminAlerts.log_missing_recipient()
      true -> hand_off(recipient)
    end
  end

  defp drop_waiting do
    case DigestEntryQueries.delete_all() do
      0 ->
        :ok

      count ->
        Logger.info("Admin alerts are switched off; dropped the waiting digest entries",
          entries: count
        )

        :ok
    end
  end

  defp hand_off(recipient) do
    result =
      Repo.transaction(fn ->
        case DigestEntryQueries.take_all() do
          [] -> 0
          entries -> schedule(recipient, entries)
        end
      end)

    case result do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Admin alert digest handed to the email worker", entries: count)
        :ok

      {:error, reason} ->
        Logger.error("Failed to hand off the admin alert digest; entries kept",
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp schedule(recipient, entries) do
    {listed, omitted} = Enum.split(entries, @max_entries)

    digest = %{
      "entries" => Enum.map(listed, &serialise_entry/1),
      "omitted" => count_by_type(omitted),
      "deployment" => AdminAlertScheduler.serialize_metadata(EmailNotifier.deployment_context())
    }

    case EmailScheduler.schedule_admin_alert_digest(recipient, digest) do
      :ok -> length(entries)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp serialise_entry(entry) do
    %{
      "alert_type" => entry.alert_type,
      "category" => entry.category,
      "message" => entry.message,
      "occurrences" => entry.occurrences,
      "first_seen_at" => timestamp(entry.inserted_at),
      "last_seen_at" => timestamp(entry.updated_at),
      "metadata" => entry.metadata
    }
  end

  defp count_by_type(entries) do
    Enum.reduce(entries, %{}, fn entry, counts ->
      Map.update(counts, entry.alert_type, entry.occurrences, &(&1 + entry.occurrences))
    end)
  end

  defp timestamp(datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
