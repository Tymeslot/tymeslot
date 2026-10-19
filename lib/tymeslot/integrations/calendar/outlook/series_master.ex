defmodule Tymeslot.Integrations.Calendar.Outlook.SeriesMaster do
  @moduledoc """
  Reads the repeat rule of an Outlook series from its master, for
  `Tymeslot.Integrations.Calendar.SeriesRules.refresh/3`: the
  `calendarView` listing the sync reads gives a series' occurrences only,
  each naming its master in `seriesMasterId`.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter
  alias Tymeslot.Integrations.Calendar.SeriesRules

  @doc "The reader `SeriesRules.refresh/3` takes, for `integration`."
  @spec reader(CalendarIntegrationSchema.t()) :: SeriesRules.read()
  def reader(%CalendarIntegrationSchema{} = integration),
    do: fn master_id, _calendar_id -> read(integration, master_id) end

  @doc """
  Reads one master. A master that is not a series has no rule; one Graph no
  longer has is `:gone`; any other failure stops the run's reads.
  """
  @spec read(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, %{rule: String.t() | nil, master_start: DateTime.t() | nil}}
          | :gone
          | {:stop, term()}
  def read(integration, master_id) do
    case Config.outlook_calendar_api_module().get_series_master(integration, master_id) do
      {:ok, %{"type" => "seriesMaster", "recurrence" => %{} = recurrence} = master} ->
        {:ok,
         %{
           rule: RecurrenceConverter.outlook_to_rrule(recurrence),
           master_start: master_start(master["start"])
         }}

      {:ok, %{}} ->
        {:ok, %{rule: nil, master_start: nil}}

      {:error, :not_found, _message} ->
        :gone

      {:error, type, _message} ->
        {:stop, type}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Reads ask Graph for UTC, so the start's wall clock is a UTC one.
  defp master_start(%{"dateTime" => value, "timeZone" => "UTC"}) when is_binary(value) do
    case NaiveDateTime.from_iso8601(String.slice(value, 0, 19)) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  defp master_start(_start), do: nil
end
