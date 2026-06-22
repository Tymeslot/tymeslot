defmodule Tymeslot.Analytics.Reconciliation do
  @moduledoc """
  Periodic self-consistency check for booking analytics.

  Cross-checks page-view events against bookings over a trailing window and
  reports the result two ways: a structured log line every run (so the numbers
  are queryable in the JSON logs) and an admin alert when an invariant breaks.

  This is the production tracking-error gauge. The checks:

    * `unique_visitors <= visits` — distinct can never exceed total within the
      same table/window; a breach means data corruption.
    * `converting_visitors` materially exceeding `unique_visitors` — bookers and
      viewers are counted from different tables, and because the visitor hash
      salt rotates daily a viewer/booker straddling UTC midnight hashes
      differently in each, so a *small* excess is expected on healthy data.
      Only an excess on a sample of at least `converting_excess_min_sample`
      distinct bookers is treated as a signal that bookings are being recorded
      without their page-view; smaller excesses are ignored as salt-boundary
      noise.
    * untracked ratio — the share of distinct bookers with no matching page-view
      event. A small ratio is normal (admin/API bookings, the odd dropped
      write); a large one means the page-view pipeline is likely broken.

  Alerts dispatch through `Tymeslot.Infrastructure.AdminAlerts`, which logs
  unconditionally and emails only when admin alerts are enabled — so a
  self-hoster without alerts configured still gets the log line, while the
  managed service gets the email.

  Thresholds are read from `config :tymeslot, :analytics_reconciliation` and
  fall back to the defaults below.
  """

  require Logger

  alias Tymeslot.Analytics
  alias Tymeslot.Analytics.ReconciliationQueries
  alias Tymeslot.Infrastructure.AdminAlerts

  @default_window_days 7
  @default_untracked_ratio_threshold 0.5
  @default_untracked_min_sample 10
  @default_converting_excess_min_sample 10

  @type anomaly :: %{kind: atom(), severity: :warning | :error, detail: String.t()}

  @doc """
  Runs reconciliation over the trailing window. No-op when booking analytics is
  disabled (nothing is collected, so there is nothing to reconcile).
  """
  @spec run() :: {:ok, :disabled} | {:ok, %{totals: map(), anomalies: [anomaly()]}}
  def run do
    if Analytics.enabled?() do
      reconcile()
    else
      {:ok, :disabled}
    end
  end

  defp reconcile do
    days = config(:window_days, @default_window_days)
    now = DateTime.utc_now()
    from = DateTime.add(now, -days * 86_400, :second)

    totals = ReconciliationQueries.instance_totals(from, now)
    anomalies = detect_anomalies(totals)

    log_result(totals, anomalies, days)
    Enum.each(anomalies, &alert(&1, totals, days))

    {:ok, %{totals: totals, anomalies: anomalies}}
  end

  @doc """
  Returns the anomalies present in a totals map. Pure — exposed for testing.
  """
  @spec detect_anomalies(ReconciliationQueries.totals()) :: [anomaly()]
  def detect_anomalies(totals) do
    Enum.reject(
      [
        check_unique_vs_visits(totals),
        check_converting_vs_unique(totals),
        check_untracked_ratio(totals)
      ],
      &is_nil/1
    )
  end

  defp check_unique_vs_visits(%{unique_visitors: unique, visits: visits})
       when unique > visits do
    %{
      kind: :unique_exceeds_visits,
      severity: :error,
      detail: "#{unique} unique visitors exceed #{visits} total visits — data integrity issue"
    }
  end

  defp check_unique_vs_visits(_totals), do: nil

  defp check_converting_vs_unique(%{converting_visitors: converting, unique_visitors: unique})
       when converting > unique do
    min_sample = config(:converting_excess_min_sample, @default_converting_excess_min_sample)

    if converting >= min_sample do
      %{
        kind: :converting_exceeds_unique,
        severity: :warning,
        detail:
          "#{converting} converting visitors exceed #{unique} unique visitors — bookings recorded without a page-view"
      }
    end
  end

  defp check_converting_vs_unique(_totals), do: nil

  defp check_untracked_ratio(%{
         converting_visitors: converting,
         untracked_converting_visitors: untracked
       }) do
    threshold = config(:untracked_ratio_threshold, @default_untracked_ratio_threshold)
    min_sample = config(:untracked_min_sample, @default_untracked_min_sample)
    ratio = if converting > 0, do: untracked / converting, else: 0.0

    if converting >= min_sample and ratio > threshold do
      %{
        kind: :high_untracked_ratio,
        severity: :warning,
        detail:
          "#{untracked}/#{converting} converting visitors (#{percent(ratio)}) have no page-view — tracking may be broken"
      }
    end
  end

  defp log_result(totals, anomalies, days) do
    Logger.info("Booking analytics reconciliation",
      window_days: days,
      visits: totals.visits,
      unique_visitors: totals.unique_visitors,
      converting_visitors: totals.converting_visitors,
      untracked_converting_visitors: totals.untracked_converting_visitors,
      untracked_ratio: percent(untracked_ratio(totals)),
      anomaly_count: length(anomalies)
    )
  end

  defp alert(anomaly, totals, days) do
    AdminAlerts.report(:analytics_tracking_anomaly,
      summary: "Booking analytics anomaly: #{anomaly.detail}",
      context: Map.merge(totals, %{kind: anomaly.kind, window_days: days})
    )
  end

  defp untracked_ratio(%{converting_visitors: 0}), do: 0.0

  defp untracked_ratio(%{
         converting_visitors: converting,
         untracked_converting_visitors: untracked
       }),
       do: untracked / converting

  defp percent(ratio), do: "#{:erlang.float_to_binary(ratio * 100, decimals: 1)}%"

  defp config(key, default) do
    :tymeslot
    |> Application.get_env(:analytics_reconciliation, %{})
    |> Map.get(key, default)
  end
end
