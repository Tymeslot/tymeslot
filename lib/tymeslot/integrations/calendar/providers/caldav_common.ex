defmodule Tymeslot.Integrations.Calendar.Providers.CaldavCommon do
  @moduledoc """
  Shared CalDAV-family provider mechanics.

  Centralizes connection testing, discovery, event fetching, and CRUD wrappers
  used by CalDAV-compatible providers (e.g., generic CalDAV, Radicale).
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.{Base, Discovery, Events}
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  @spec normalize_url(String.t()) :: String.t()
  def normalize_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  @doc """
  Builds a client map for downstream Base.* functions.
  Expects keys: :base_url, :username, :password, :calendar_paths, :verify_ssl
  Options: provider: atom()
  """
  @spec build_client(map(), keyword()) :: map()
  def build_client(config, opts) when is_map(config) do
    provider = Keyword.fetch!(opts, :provider)

    %{
      base_url: normalize_url(Map.get(config, :base_url) || Map.get(config, "base_url")),
      username: Map.get(config, :username) || Map.get(config, "username"),
      password: Map.get(config, :password) || Map.get(config, "password"),
      calendar_paths: Map.get(config, :calendar_paths) || [],
      verify_ssl: Map.get(config, :verify_ssl, true),
      provider: provider
    }
  end

  @doc """
  Tests a connection using `Discovery.test_connection/2`.
  Returns `{:ok, message}` or `{:error, reason}` (reason is passed through).
  """
  @spec test_connection(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def test_connection(client, opts \\ []) do
    case Discovery.test_connection(client, opts) do
      {:ok, _result} -> {:ok, success_message(client.provider)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Discovers available calendars via `Discovery.discover_calendars/2`.
  """
  @spec discover_calendars(map(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def discover_calendars(client, opts \\ []) do
    Discovery.discover_calendars(client, opts)
  end

  @doc """
  Fetch events for default current month.
  """
  @spec get_events(map()) :: {:ok, list()} | {:error, term()}
  def get_events(client) do
    now = DateTime.utc_now()
    {:ok, start_time} = DateTime.new(Date.beginning_of_month(now), ~T[00:00:00], "Etc/UTC")
    {:ok, end_time} = DateTime.new(Date.end_of_month(now), ~T[23:59:59], "Etc/UTC")
    get_events(client, start_time, end_time)
  end

  @doc """
  Fetch events for a given time window across all configured calendars in parallel.
  """
  @spec get_events(map(), DateTime.t(), DateTime.t()) :: {:ok, list()} | {:error, term()}
  def get_events(client, start_time, end_time) do
    paths = get_calendar_paths(client)

    if Enum.empty?(paths) do
      {:error, "No calendars configured"}
    else
      do_fetch_events(client, paths, start_time, end_time)
    end
  end

  defp do_fetch_events(client, paths, start_time, end_time) do
    tasks =
      Enum.map(paths, fn path ->
        Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
          Events.fetch_events(client, path, start_time, end_time)
        end)
      end)

    results = Task.await_many(tasks, Base.task_await_timeout_ms())

    events =
      results
      |> Enum.filter(&match?({:ok, _result}, &1))
      |> Enum.flat_map(fn {:ok, evs} -> evs end)
      |> Enum.uniq_by(& &1.uid)

    {:ok, expand_recurring_events(events, start_time, end_time)}
  end

  @doc """
  Create an event in the first configured calendar.
  """
  @spec create_event(map(), map()) :: {:ok, any()} | {:error, term()}
  def create_event(client, event_data) do
    case primary_calendar_path(client) do
      nil -> {:error, "No calendar configured for creating events"}
      path -> Events.create_calendar_event(client, path, event_data)
    end
  end

  @doc """
  Update an event by UID in the primary configured calendar.
  """
  @spec update_event(map(), String.t(), map()) :: :ok | {:error, term()}
  def update_event(client, uid, event_data) do
    case primary_calendar_path(client) do
      nil -> {:error, "Event not found"}
      path -> Events.update_calendar_event(client, path, uid, event_data)
    end
  end

  @doc """
  Delete an event by UID in the primary configured calendar.
  """
  @spec delete_event(map(), String.t()) :: :ok | {:error, term()}
  def delete_event(client, uid) do
    case primary_calendar_path(client) do
      nil -> :ok
      path -> Events.delete_calendar_event(client, path, uid)
    end
  end

  @doc """
  Expands recurring events (those with an RRULE) into individual occurrences
  within the given date range. Non-recurring events pass through unchanged.

  This is the CalDAV equivalent of Google Calendar's `singleEvents=true` —
  the availability layer receives concrete occurrences instead of master
  events with recurrence rules.
  """
  @spec expand_recurring_events([map()], DateTime.t(), DateTime.t()) :: [map()]
  def expand_recurring_events(events, range_start, range_end) do
    Enum.flat_map(events, fn event ->
      exdates = Map.get(event, :exdates, [])
      RecurrenceExpander.expand(event, range_start, range_end, exdates: exdates)
    end)
  end

  # Helpers
  defp get_calendar_paths(client), do: client[:calendar_paths] || client["calendar_paths"] || []

  defp primary_calendar_path(client) do
    client
    |> get_calendar_paths()
    |> List.first()
  end

  defp success_message(:radicale), do: "Radicale connection successful"
  defp success_message(_arg), do: "CalDAV connection successful"
end
