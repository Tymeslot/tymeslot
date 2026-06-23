defmodule Tymeslot.Analytics.Telemetry do
  @moduledoc """
  Telemetry for the booking-analytics ingestion path.

  `Tymeslot.Analytics.log_page_view/1` emits one
  `[:tymeslot, :analytics, :page_view]` event per call, tagged with the
  outcome (`:ok`, `:disabled`, `:filtered_owner`, `:filtered_bot`,
  `:filtered_rate_limit`, `:error`). The page-view write happens in a fire-and-forget Task whose
  return value is discarded, so without this every dropped or failed write
  was silent. The attached handler logs the outcomes that represent lost or
  dropped data; the healthy paths are counted only, to avoid per-request log
  noise. Every outcome is also available as a counter to any metrics reporter
  that gets attached later (see `TymeslotWeb.Telemetry.metrics/0`).
  """

  require Logger

  @event [:tymeslot, :analytics, :page_view]

  @doc "The single telemetry event emitted by the analytics ingestion path."
  @spec event() :: [atom()]
  def event, do: @event

  @doc "Emits the ingestion outcome. Called once per `Analytics.log_page_view/1`."
  @spec emit(atom()) :: :ok
  def emit(outcome) when is_atom(outcome) do
    :telemetry.execute(@event, %{count: 1}, %{outcome: outcome})
  end

  @doc "Attaches the logging handler. Called once at application start."
  @spec attach_default_handler() :: :ok | {:error, :already_exists}
  def attach_default_handler do
    :telemetry.attach(
      "tymeslot-analytics-page-view-logger",
      @event,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(@event, _measurements, %{outcome: outcome}, _config) do
    case log_level(outcome) do
      nil ->
        :ok

      level ->
        Logger.log(level, "Booking analytics page view dropped: #{outcome}", outcome: outcome)
    end
  end

  # Only surface outcomes that mean data was lost or a real visitor was dropped.
  # A sustained :filtered_rate_limit usually means NAT'd traffic being shed; an
  # :error means an event write failed. The healthy paths (:ok, :filtered_bot,
  # :disabled) are counted via telemetry but never logged.
  defp log_level(:filtered_rate_limit), do: :warning
  defp log_level(:error), do: :warning
  defp log_level(_other), do: nil
end
