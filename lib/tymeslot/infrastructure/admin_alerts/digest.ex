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

  ## The error roll-up

  The same storage and hand-off carry a second batch, `"errors"`: the error
  alerts `Tymeslot.Infrastructure.AdminAlerts.ErrorBurst` held back once the
  hour's immediate emails were spent. `deliver("errors")` runs when that
  window frees a slot, and lists the newest `ErrorBurst.listed/0` entries
  instead of the oldest hundred, counting the rest by type. Each batch is
  delivered, and dropped, on its own.
  """

  require Logger

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.DigestEntryQueries
  alias Tymeslot.Infrastructure.AdminAlerts.EmailNotifier
  alias Tymeslot.Infrastructure.AdminAlerts.ErrorBurst
  alias Tymeslot.Infrastructure.ErrorTracking.ErrorTrackingQueries
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker.AdminAlertScheduler

  @max_entries 100

  @daily "daily"
  @errors "errors"

  @doc "The batch of the error roll-up, beside the daily digest's `\"daily\"`."
  @spec errors_batch() :: String.t()
  def errors_batch, do: @errors

  @doc """
  Records an alert for the next email of `batch`: an info alert for the
  daily digest (the default), or an error alert `ErrorBurst` held back for
  its roll-up (`"errors"`). `metadata` must already be scrubbed; `dedup_key`
  is the alert's `AlertTypes.dedup_key/2` (or `ErrorBurst`'s per-error key),
  built from the raw metadata and stored only as a hash.
  """
  @spec record(atom(), String.t(), String.t(), map(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def record(type, category, message, metadata, dedup_key, batch \\ @daily) do
    attrs = %{
      batch: batch,
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
          error: LogFormat.reason(reason)
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
  @spec deliver(String.t()) :: :ok | {:error, term()}
  def deliver(batch \\ @daily) when batch in [@daily, @errors] do
    recipient = AdminAlerts.recipient()

    cond do
      not AdminAlerts.enabled?() -> drop_waiting(batch)
      not AdminAlerts.valid_email?(recipient) -> AdminAlerts.log_missing_recipient()
      true -> hand_off(batch, recipient)
    end
  end

  defp drop_waiting(batch) do
    case DigestEntryQueries.delete_all(batch) do
      0 ->
        :ok

      count ->
        Logger.info("Admin alerts are switched off; dropped the waiting digest entries",
          entries: count,
          batch: batch
        )

        :ok
    end
  end

  defp hand_off(batch, recipient) do
    result =
      Repo.transaction(fn ->
        case DigestEntryQueries.take_all(batch) do
          [] -> 0
          entries -> schedule(batch, recipient, entries)
        end
      end)

    case result do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Admin alert digest handed to the email worker", entries: count, batch: batch)
        :ok

      {:error, reason} ->
        Logger.error("Failed to hand off the admin alert digest; entries kept",
          error: LogFormat.reason(reason),
          batch: batch
        )

        {:error, reason}
    end
  end

  defp schedule(batch, recipient, entries) do
    {listed, omitted} = batch |> in_listing_order(entries) |> Enum.split(listing_limit(batch))

    digest = %{
      "kind" => batch,
      "entries" => serialise_entries(batch, listed),
      "omitted" => count_by_type(omitted),
      "deployment" => AdminAlertScheduler.serialize_metadata(EmailNotifier.deployment_context())
    }

    case EmailScheduler.schedule_admin_alert_digest(recipient, digest) do
      :ok -> length(entries)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The daily digest lists the oldest, in the order they arrived. The error
  # roll-up lists the most recently seen, newest first: after a bad deploy,
  # the latest failures are the ones worth reading first.
  defp in_listing_order(@daily, entries), do: entries

  defp in_listing_order(@errors, entries),
    do: Enum.sort_by(entries, &{DateTime.to_unix(&1.updated_at, :microsecond), &1.id}, :desc)

  defp listing_limit(@daily), do: @max_entries
  defp listing_limit(@errors), do: ErrorBurst.listed()

  defp serialise_entries(@daily, listed), do: Enum.map(listed, &serialise_entry/1)

  # Each roll-up entry also says how often its error has happened in all, as
  # stored: the alert fires once per error, so its own count says little.
  defp serialise_entries(@errors, listed) do
    counts =
      listed
      |> Enum.map(& &1.metadata["error_id"])
      |> Enum.filter(&is_integer/1)
      |> ErrorTrackingQueries.occurrence_counts()

    Enum.map(listed, fn entry ->
      case Map.fetch(counts, entry.metadata["error_id"]) do
        {:ok, count} -> Map.put(serialise_entry(entry), "error_occurrences", count)
        :error -> serialise_entry(entry)
      end
    end)
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
