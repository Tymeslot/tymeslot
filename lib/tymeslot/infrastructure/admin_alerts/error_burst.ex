defmodule Tymeslot.Infrastructure.AdminAlerts.ErrorBurst do
  @moduledoc """
  Caps how many error alerts (`:new_error`, `:error_regression`) are emailed
  one by one, folding the rest into a single roll-up email.

  Each distinct error is its own alert, deduplicated only against itself, so
  a deploy that breaks ten call sites, or the first run after a deploy that
  meets every long-standing handled error again, would otherwise send an
  email per error in the same few minutes.

  ## The rule

  Over a rolling window (`window_seconds`, default an hour) the first
  `immediate_per_window` error alerts (default 3) are emailed at once, as
  before. Every further one is recorded as a digest entry in the `"errors"`
  batch (`Tymeslot.Infrastructure.AdminAlerts.Digest`), keyed on the error,
  so repeats of one error collapse into one counted entry, and a roll-up
  delivery is scheduled for the moment the window frees a slot: an hour
  after the oldest of the alerts that filled it. That delivery sends one
  email listing the newest `listed` entries (default 10) and counting the
  rest by type. In the worst case the operator gets
  `immediate_per_window` emails and one roll-up an hour.

      config :tymeslot, :error_alert_burst,
        immediate_per_window: 3,
        window_seconds: 3_600,
        listed: 10

  ## Cluster safety

  The state is the database's, never a process's. The alerts already
  emailed are the admin alert email jobs Oban holds (its Pruner keeps a
  week, far longer than the window). The decision runs in a transaction
  under an advisory lock, so two nodes cannot both see the last free slot.
  The roll-up job is unique while it waits, so however many alerts overflow
  one is pending at a time, and it hands the entries to the email worker in
  the transaction that deletes them, from where the email retries on the
  admin alert schedule: a mail outage loses nothing.
  """

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.AdminAlerts.Digest
  alias Tymeslot.Infrastructure.AdminAlerts.DigestEntryQueries
  alias Tymeslot.Jobs.ObanJobQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AdminAlertDigestWorker
  alias Tymeslot.Workers.EmailWorker

  @types [:new_error, :error_regression]

  @default_immediate_per_window 3
  @default_window_seconds 3_600
  @default_listed 10

  @typedoc "An alert as `EmailNotifier` hands it on: metadata already scrubbed."
  @type alert ::
          {type :: atom(), category :: String.t(), severity :: atom(), message :: String.t(),
           metadata :: map(), dedup_key :: String.t()}

  @doc "Whether alerts of `type` are subject to the burst cap."
  @spec applies?(atom()) :: boolean()
  def applies?(type), do: type in @types

  @doc "How many of the newest held-back alerts one roll-up email lists."
  @spec listed() :: pos_integer()
  def listed, do: setting(:listed, @default_listed)

  @doc """
  Emails `alert` to `recipient` at once, or holds it for the roll-up when
  the window's allowance is spent. `enriched_metadata` is what the
  immediate email carries (the alert's metadata plus the deployment
  context); a held-back alert stores the plain metadata, and the roll-up
  adds the deployment context once.
  """
  @spec deliver(alert(), map(), String.t()) :: :ok | {:error, term()}
  def deliver(alert, enriched, recipient) do
    window_seconds = setting(:window_seconds, @default_window_seconds)
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        :ok = DigestEntryQueries.lock_error_burst()

        case decide(alert, enriched, recipient, now, window_seconds) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp decide(alert, enriched, recipient, now, window_seconds) do
    {_type, category, severity, message, _metadata, dedup_key} = alert
    {count, oldest} = emailed_in_window(category, now, window_seconds)

    if count < setting(:immediate_per_window, @default_immediate_per_window) do
      EmailScheduler.schedule_admin_alert(recipient, category, severity, message, enriched,
        dedup_key: dedup_key
      )
    else
      # The window frees a slot when its oldest email leaves it.
      hold(alert, DateTime.add(oldest || now, window_seconds, :second), now)
    end
  end

  defp emailed_in_window(category, now, window_seconds) do
    ObanJobQueries.count_inserted_since(
      EmailWorker,
      %{"action" => "send_admin_alert", "category" => category},
      DateTime.add(now, -window_seconds, :second)
    )
  end

  # Keyed on the error rather than the alert, so a new error and its later
  # regressions held in one window read as one entry with a count.
  defp hold({type, category, _severity, message, metadata, dedup_key}, due_at, now) do
    key =
      case Map.get(metadata, :error_id) do
        nil -> dedup_key
        error_id -> "error_burst:#{error_id}"
      end

    with :ok <- Digest.record(type, category, message, metadata, key, Digest.errors_batch()) do
      schedule_roll_up(Enum.max([due_at, DateTime.add(now, 1, :second)], DateTime))
    end
  end

  # Unique among the waiting roll-ups, not the running one: an alert held
  # while a roll-up is sending starts the next.
  defp schedule_roll_up(at) do
    job =
      AdminAlertDigestWorker.new(%{"batch" => Digest.errors_batch()},
        scheduled_at: at,
        unique: [period: :infinity, fields: [:worker, :args], states: [:scheduled, :available]]
      )

    case Oban.insert(job) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp setting(key, default) do
    :tymeslot
    |> Application.get_env(:error_alert_burst, [])
    |> Keyword.get(key, default)
  end
end
