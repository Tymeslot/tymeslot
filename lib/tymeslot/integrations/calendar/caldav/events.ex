defmodule Tymeslot.Integrations.Calendar.CalDAV.Events do
  @moduledoc """
  CalDAV event operations domain.

  Owns the full lifecycle of calendar event CRUD:

  - **ETag-conditional updates**: HEAD → extract ETag → PUT with `If-Match`,
    preventing lost updates when two parties edit the same event concurrently.
  - **iCal construction**: builds valid RFC 5545 event payloads from domain maps.
  - **Per-operation retry policies**: reads retry on transient failures; writes
    do not (retrying a write without idempotency guarantees is unsafe).
  - **Circuit breaker protection** for all operations.

  Callers receive parsed domain types — never raw HTTP responses, XML, or iCal.
  """

  alias Tymeslot.Infrastructure.{CalendarCircuitBreaker, RetryLogic}
  alias Tymeslot.Integrations.Calendar.CalDAV.{Base, Http, UrlBuilder, XmlHandler}
  alias Tymeslot.Integrations.Calendar.ICalBuilder

  require Logger

  @doc """
  Fetches events from a calendar within the given time range.

  Applies retry logic for transient failures — reads are safe to retry.
  Returns parsed event maps with domain fields (`uid`, `summary`, etc.).
  """
  @spec fetch_events(Base.client(), String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, list(XmlHandler.parsed_event())} | {:error, Base.error_reason()}
  def fetch_events(client, calendar_path, start_time, end_time, opts \\ []) do
    with_events_breaker(client, opts, fn ->
      url = UrlBuilder.build_calendar_url(client.base_url, calendar_path)
      report_body = XmlHandler.build_calendar_query(start_time, end_time)

      retry_opts = Keyword.get(opts, :retry_opts, Base.default_retry_opts())

      report_opts =
        Keyword.put(opts, :timeout, Keyword.get(opts, :timeout, Base.report_timeout_ms()))

      case RetryLogic.with_retry(
             fn ->
               Http.report(url, client.username, client.password, report_body, report_opts)
             end,
             retry_opts
           ) do
        {:ok, %Req.Response{status: 207, body: body}} ->
          XmlHandler.parse_calendar_query(body)

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          # Some servers return 200 instead of the CalDAV-mandated 207 Multi-Status
          Logger.warning("CalDAV REPORT returned unexpected status",
            status: status,
            expected: 207,
            url: url,
            provider: Map.get(client, :provider, :caldav)
          )

          XmlHandler.parse_calendar_query(body)

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Creates a new event in the calendar.

  Generates a UID if not supplied in `event_data`. Returns `{:ok, uid}` on
  success, where `uid` is the stable identifier for future updates and deletes.
  Uses `If-None-Match: *` to prevent accidental overwrites.
  """
  @spec create_calendar_event(Base.client(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, Base.error_reason()}
  def create_calendar_event(client, calendar_path, event_data, opts \\ []) do
    uid = event_data[:uid] || ICalBuilder.generate_uid()
    ical_data = ICalBuilder.build_simple_event(uid, event_data)
    put_ical(client, calendar_path, uid, ical_data, opts)
  end

  @doc """
  Creates a new event in the calendar from a pre-built iCalendar payload.

  Skips `ICalBuilder` entirely — the caller is responsible for producing a
  valid RFC 5545 document. Used by `mix calendar_audit` to exercise
  adversarial server-generated payloads (e.g. Zimbra-style quoted TZIDs)
  that Tymeslot's own writer never produces.
  """
  @spec put_raw_event(Base.client(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Base.error_reason()}
  def put_raw_event(client, calendar_path, uid, ical_data, opts \\ []) do
    put_ical(client, calendar_path, uid, ical_data, opts)
  end

  defp put_ical(client, calendar_path, uid, ical_data, opts) do
    with_events_breaker(client, opts, fn ->
      url = UrlBuilder.build_event_url(client.base_url, calendar_path, uid)
      put_opts = Keyword.merge([operation: :create], Keyword.take(opts, [:timeout]))

      case Http.put_event(url, client.username, client.password, ical_data, put_opts) do
        {:ok, %Req.Response{status: status}} when status in [200, 201, 204] -> {:ok, uid}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Updates an existing event.

  Fetches the current ETag via HEAD to enable a conditional `If-Match` write,
  preventing lost updates when two parties edit the same event concurrently.
  Falls back to `If-Match: *` if the HEAD request fails or times out, which
  is safe but allows unconditional overwrite.
  """
  @spec update_calendar_event(Base.client(), String.t(), String.t(), map(), keyword()) ::
          :ok | {:error, Base.error_reason()}
  def update_calendar_event(client, calendar_path, uid, event_data, opts \\ []) do
    with_events_breaker(client, opts, fn ->
      url = event_url_from_data(client, calendar_path, uid, event_data)
      ical_data = ICalBuilder.build_simple_event(uid, Map.put(event_data, :uid, uid))
      etag = fetch_current_etag(url, client, opts)

      base_put_opts =
        if etag, do: [operation: :update, if_match: etag], else: [operation: :update]

      put_opts = Keyword.merge(base_put_opts, Keyword.take(opts, [:timeout]))

      case Http.put_event(url, client.username, client.password, ical_data, put_opts) do
        {:ok, %Req.Response{status: status}} when status in [200, 201, 204] -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Deletes an event from the calendar. Idempotent — succeeds if already gone.
  """
  @spec delete_calendar_event(Base.client(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Base.error_reason()}
  def delete_calendar_event(client, calendar_path, uid, opts \\ []) do
    with_events_breaker(client, opts, fn ->
      url = UrlBuilder.build_event_url(client.base_url, calendar_path, uid)
      delete_opts = Keyword.take(opts, [:timeout])

      case Http.delete_event(url, client.username, client.password, delete_opts) do
        {:ok, %Req.Response{}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # Use the event's href (provider_event_id) when available — it's the actual
  # server path. Fall back to UID-based URL construction for Tymeslot-created events.
  defp event_url_from_data(client, calendar_path, uid, event_data) do
    case Map.get(event_data, :provider_event_id) do
      href when is_binary(href) and href != "" ->
        base = String.trim_trailing(client.base_url, "/")
        if String.starts_with?(href, "http"), do: href, else: "#{base}#{href}"

      _missing ->
        UrlBuilder.build_event_url(client.base_url, calendar_path, uid)
    end
  end

  # HEAD → extract ETag for conditional PUT. Short timeout since ETag is optional:
  # if HEAD times out we proceed without it rather than failing the entire update.
  defp fetch_current_etag(url, client, opts) do
    head_timeout = Keyword.get(opts, :head_timeout, 15_000)
    head_opts = Keyword.put(opts, :timeout, head_timeout)

    case Http.head_event(url, client.username, client.password, head_opts) do
      {:ok, %{headers: headers}} ->
        case Map.get(headers, "etag") do
          [etag | _rest] -> etag
          _other -> nil
        end

      _error ->
        nil
    end
  end

  defp with_events_breaker(client, opts, fun) when is_function(fun, 0) do
    provider = Map.get(client, :provider, :caldav)
    host = Base.extract_host_from_url(client.base_url)
    opts = Keyword.put(opts, :host, host)
    CalendarCircuitBreaker.with_breaker(provider, opts, fun)
  end
end
