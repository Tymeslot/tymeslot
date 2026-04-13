defmodule Tymeslot.Integrations.Calendar.Providers.CaldavCommon do
  @moduledoc """
  Shared CalDAV-family provider mechanics.

  Centralizes connection testing, discovery, event fetching, and CRUD wrappers
  used by CalDAV-compatible providers (e.g., generic CalDAV, Radicale).
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.{Base, Discovery, Events, Http, UrlBuilder}
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  require Logger

  @type caldav_client :: %{
          required(:base_url) => String.t(),
          required(:username) => String.t() | nil,
          required(:password) => String.t() | nil,
          required(:calendar_paths) => [String.t()],
          required(:verify_ssl) => boolean(),
          required(:provider) => atom()
        }

  @spec normalize_url(String.t() | nil) :: String.t()
  def normalize_url(nil), do: ""

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
  @spec build_client(%{atom() => term()}, keyword()) :: caldav_client()
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
  Quick connectivity probe via a PROPFIND request with a short timeout.

  Sends a minimal PROPFIND to the first configured calendar path (or `/`) to
  verify that the server is reachable and credentials are accepted. Intended
  for use by the audit runner and diagnostic tooling; not a substitute for
  `test_connection/2`, which performs a fuller discovery-based check.

  Returns `{:ok, %{status: :ok}}` on success, or `{:error, reason}`.
  """
  @spec check_connectivity(caldav_client()) :: {:ok, map()} | {:error, term()}
  def check_connectivity(client) do
    path = List.first(client[:calendar_paths] || []) || "/"

    # Use the same URL builder as create/read/delete so server-root-relative
    # paths (e.g. Nextcloud's "/remote.php/dav/calendars/...") aren't
    # double-prefixed when the client's base_url already contains a CalDAV
    # principal path.
    url = UrlBuilder.build_calendar_url(client[:base_url], path)

    case Http.propfind(url, client[:username], client[:password],
           depth: "0",
           timeout: 5_000
         ) do
      {:ok, _response} -> {:ok, %{status: :ok}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Tests a connection using `Discovery.test_connection/2`.
  Returns `{:ok, message}` or `{:error, reason}` (reason is passed through).
  """
  @spec test_connection(caldav_client(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def test_connection(client, opts \\ []) do
    case Discovery.test_connection(client, opts) do
      {:ok, _result} -> {:ok, success_message(client.provider)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Discovers available calendars via `Discovery.discover_calendars/2`.
  """
  @spec discover_calendars(caldav_client(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def discover_calendars(client, opts \\ []) do
    Discovery.discover_calendars(client, opts)
  end

  @doc """
  Implements the `Provider` `list_events/2` contract for CalDAV-family providers.

  Extracts `:start_time` and `:end_time` from `opts` and delegates to
  `get_events/3`. Returns `{:error, :missing_time_range}` when either value is
  absent or not a `DateTime`.
  """
  @spec list_events(caldav_client(), keyword()) :: {:ok, list()} | {:error, term()}
  def list_events(client, opts) do
    case {opts[:start_time], opts[:end_time]} do
      {%DateTime{} = start_time, %DateTime{} = end_time} ->
        get_events(client, start_time, end_time)

      _missing_range ->
        {:error, :missing_time_range}
    end
  end

  @doc """
  Fetch events for default current month.
  """
  @spec get_events(caldav_client()) :: {:ok, list()} | {:error, term()}
  def get_events(client) do
    now = DateTime.utc_now()
    {:ok, start_time} = DateTime.new(Date.beginning_of_month(now), ~T[00:00:00], "Etc/UTC")
    {:ok, end_time} = DateTime.new(Date.end_of_month(now), ~T[23:59:59], "Etc/UTC")
    get_events(client, start_time, end_time)
  end

  @doc """
  Fetch events for a given time window across all configured calendars in parallel.
  """
  @spec get_events(caldav_client(), DateTime.t(), DateTime.t()) ::
          {:ok, list()} | {:error, term()}
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
        {path,
         Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
           Events.fetch_events(client, path, start_time, end_time)
         end)}
      end)

    results =
      Enum.map(tasks, fn {path, task} ->
        {path, Task.await(task, Base.task_await_timeout_ms())}
      end)

    {successes, errors} =
      Enum.split_with(results, fn {_path, r} -> match?({:ok, _result}, r) end)

    handle_fetch_results(successes, errors)
  end

  # If every calendar path errored, surface the first error — callers must be
  # able to distinguish "no events in range" from "reads silently failed". A
  # dropped error here was the cause of today's "event not found after create"
  # mystery on Radicale: REPORT hit its timeout, the task errored, and we
  # silently returned an empty list.
  defp handle_fetch_results([], [_head | _tail] = errors) do
    {_path, {:error, reason}} = List.first(errors)
    {:error, reason}
  end

  # At least one path succeeded. Log any failures for visibility, then return
  # the union of successful results. This keeps degraded multi-calendar
  # setups working while still making errors observable in logs.
  #
  # We deliberately don't expand recurrences here — `event_processor.normalise_events`
  # does its own expansion downstream. Expanding in both places produces N×N
  # occurrences because each first-pass occurrence still carries the master
  # RRULE and gets re-expanded.
  defp handle_fetch_results(successes, errors) do
    Enum.each(errors, fn {path, {:error, reason}} ->
      Logger.warning("CalDAV fetch failed for one calendar path",
        path: path,
        reason: inspect(reason)
      )
    end)

    events =
      successes
      |> Enum.flat_map(fn {_path, {:ok, evs}} -> evs end)
      |> Enum.uniq_by(& &1.uid)

    {:ok, events}
  end

  @doc """
  Create an event in the first configured calendar.
  """
  @spec create_event(caldav_client(), map()) :: {:ok, any()} | {:error, term()}
  def create_event(client, event_data) do
    case primary_calendar_path(client) do
      nil -> {:error, "No calendar configured for creating events"}
      path -> Events.create_calendar_event(client, path, event_data)
    end
  end

  @doc """
  Update an event by UID in the primary configured calendar.
  """
  @spec update_event(caldav_client(), String.t(), map()) :: :ok | {:error, term()}
  def update_event(client, uid, event_data) do
    case primary_calendar_path(client) do
      nil -> {:error, "Event not found"}
      path -> Events.update_calendar_event(client, path, uid, event_data)
    end
  end

  @doc """
  Delete an event by UID in the primary configured calendar.
  """
  @spec delete_event(caldav_client(), String.t()) :: :ok | {:error, term()}
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
  @spec expand_recurring_events([map()], DateTime.t() | Date.t(), DateTime.t() | Date.t()) ::
          [map()]
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
