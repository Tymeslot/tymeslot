defmodule Tymeslot.Integrations.Calendar.Google.SeriesMaster do
  @moduledoc """
  Reads the repeat rule of a Google series from its recurring event, for
  `Tymeslot.Integrations.Calendar.SeriesRules.refresh/3`: the sync lists
  events with `singleEvents=true`, which gives a series' instances only,
  each naming its recurring event in `recurringEventId`.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.SeriesRules

  @doc "The reader `SeriesRules.refresh/3` takes, for `integration`."
  @spec reader(CalendarIntegrationSchema.t()) :: SeriesRules.read()
  def reader(%CalendarIntegrationSchema{} = integration),
    do: &read(integration, &1, &2)

  @doc """
  Reads one recurring event, in `calendar_id` (the primary calendar when not
  known). One without recurrence lines has no rule; one Google no longer has
  is `:gone`; any other failure stops the run's reads.
  """
  @spec read(CalendarIntegrationSchema.t(), String.t(), String.t() | nil) ::
          {:ok, %{rule: String.t() | nil, master_start: DateTime.t() | nil}}
          | :gone
          | {:stop, term()}
  def read(integration, master_id, calendar_id) do
    api = Config.google_calendar_api_module()

    case api.get_series_master(integration, calendar_id || "primary", master_id) do
      {:ok, %{} = master} ->
        {:ok,
         %{
           rule: RRule.from_lines(master["recurrence"]),
           master_start: master_start(master["start"])
         }}

      {:error, type, _message} when type in [:not_found, :gone] ->
        :gone

      {:error, type, _message} ->
        {:stop, type}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp master_start(%{"dateTime" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp master_start(%{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  defp master_start(_start), do: nil
end
