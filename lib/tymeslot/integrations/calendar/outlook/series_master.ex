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
  Reads one master: its rule, first start and iCalendar UID, which no
  occurrence carries (each has its own). A master that is not a series has
  no rule; one Graph no longer has is `:gone`; any other failure stops the
  run's reads.
  """
  @spec read(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, found()} | :gone | {:stop, term()}
  def read(integration, master_id) do
    case fetch(integration, master_id) do
      {:ok, master} -> {:ok, found(master)}
      other -> other
    end
  end

  @typedoc "What a read of a master found, as `SeriesRules` stores it."
  @type found :: %{
          rule: String.t() | nil,
          master_start: DateTime.t() | nil,
          ical_uid: String.t() | nil
        }

  @doc """
  The master `master_id` as Graph gives it, with every field
  `Outlook.OccurrenceStubs` completes a stub from: `:gone` when Graph no
  longer has it, `{:stop, reason}` for any other failure.
  """
  @spec fetch(CalendarIntegrationSchema.t(), String.t()) :: {:ok, map()} | :gone | {:stop, term()}
  def fetch(integration, master_id) do
    case Config.outlook_calendar_api_module().get_series_master(integration, master_id) do
      {:ok, %{} = master} -> {:ok, master}
      {:error, :not_found, _message} -> :gone
      {:error, type, _message} -> {:stop, type}
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc "What `read/2` answers for `master`, a master `fetch/2` read."
  @spec found(map()) :: found()
  def found(%{"type" => "seriesMaster", "recurrence" => %{} = recurrence} = master) do
    %{
      rule: RecurrenceConverter.outlook_to_rrule(recurrence),
      master_start: master_start(master["start"]),
      ical_uid: master["iCalUId"]
    }
  end

  def found(%{}), do: %{rule: nil, master_start: nil, ical_uid: nil}

  # Reads ask Graph for UTC, so the start's wall clock is a UTC one.
  defp master_start(%{"dateTime" => value, "timeZone" => "UTC"}) when is_binary(value) do
    case NaiveDateTime.from_iso8601(String.slice(value, 0, 19)) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  defp master_start(_start), do: nil
end
