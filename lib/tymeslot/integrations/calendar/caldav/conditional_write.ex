defmodule Tymeslot.Integrations.Calendar.CalDAV.ConditionalWrite do
  @moduledoc """
  The conditional write every CalDAV update goes through: read a resource
  with its ETag, and PUT a new document back under `If-Match` so that a
  concurrent change is detected rather than overwritten.

  A `412 Precondition Failed` is resolved by the caller's
  `ConflictResolution` policy. A server that answers a conditional PUT with
  `409` instead of `412` follows the same policy when a real ETag was sent;
  when only `If-Match: *` was sent the write is simply replayed
  unconditionally, since that condition guarded nothing.
  """

  alias Tymeslot.Infrastructure.RetryLogic
  alias Tymeslot.Integrations.Calendar.CalDAV.{Base, ConflictResolution, Http}

  require Logger

  @doc """
  Reads the resource at `url`: its iCalendar document and the ETag it came
  with, the pair a rewrite has to start from. `{:error, :not_found}` when the
  server has no event there.
  """
  @spec fetch_document(Base.client(), String.t(), keyword()) ::
          {:ok, String.t(), String.t() | nil} | {:error, Base.error_reason()}
  def fetch_document(client, url, opts) do
    get_opts = Keyword.put(opts, :timeout, Keyword.get(opts, :read_timeout, 30_000))

    case Http.get_event(url, client.username, client.password, get_opts) do
      {:ok, %Req.Response{body: body, headers: headers}} when is_binary(body) and body != "" ->
        {:ok, body, etag_from_headers(headers)}

      # A 200 with nothing in it describes no event, so there is nothing to
      # preserve: treat it as the absent resource it looks like.
      {:ok, %Req.Response{}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  PUTs `ical_data` to `url` under `If-Match: <etag>`, or `If-Match: *` when
  `etag` is `nil`, resolving a rejected precondition by `policy` (see
  `ConflictResolution`).
  """
  @spec put(
          Base.client(),
          String.t(),
          String.t(),
          String.t() | nil,
          ConflictResolution.t(),
          keyword()
        ) ::
          :ok | {:error, Base.error_reason()}
  def put(client, url, ical_data, etag, policy, opts) do
    base_put_opts =
      if etag, do: [operation: :update, if_match: etag], else: [operation: :update]

    put_opts = Keyword.merge(base_put_opts, Keyword.take(opts, [:timeout]))

    put_fun = fn ->
      Http.put_event(url, client.username, client.password, ical_data, put_opts)
    end

    # If-Match PUTs (with a specific ETag or with *) are safe to retry: the
    # server will either apply the write or reject it with 412. The
    # duplicate-creation risk only applies to If-None-Match: * creates, which
    # go through put_ical/5, not this function. So we always apply retry here,
    # regardless of whether we have a specific ETag or fell back to If-Match: *.
    retry_opts = Keyword.get(opts, :retry_opts, Base.default_retry_opts())
    raw_result = RetryLogic.with_retry(put_fun, retry_opts)

    case raw_result do
      {:ok, %Req.Response{status: status}} when status in [200, 201, 204] ->
        :ok

      # With no ETag all we sent was `If-Match: *`, which asserts nothing but
      # that the resource exists (RFC 7232 §3.1), so a 412 against it should
      # mean the event is absent. Not every server keeps to that: iCloud
      # refuses `If-Match: *` on an event it holds. The server is asked
      # before the event is reported missing, since a wrong `:not_found` sends
      # `CalendarEventSync` to recreate an event that is still there.
      {:error, :precondition_failed} when is_nil(etag) ->
        put_after_refused_wildcard(client, url, ical_data, policy, opts)

      {:error, :precondition_failed} ->
        handle_precondition_failed(client, url, ical_data, policy, opts)

      # The server rejected the conditional PUT with a 409. When all we sent
      # was `If-Match: *` there was no ETag and therefore no lost-update
      # protection to preserve — the condition asserted only that the event
      # exists — so replaying it unconditionally loses nothing and gets the
      # write through on servers that mishandle the conditional form.
      {:error, :conditional_not_supported} when is_nil(etag) ->
        Logger.warning("CalDAV server rejected If-Match: *, retrying unconditionally")
        force_put(client, url, ical_data, opts)

      # With a real ETag the condition did carry a guarantee, so treat the 409
      # as the precondition failure the server meant it to be and let the
      # configured policy decide.
      {:error, :conditional_not_supported} ->
        handle_precondition_failed(client, url, ical_data, policy, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Absence is reported as `:not_found`, which is what lets `CalendarEventSync`
  # recreate an event that never landed or was deleted in the organiser's
  # client; none of the conflict policies can, since each assumes a server
  # copy to reconcile against. An event that is there after all is written
  # under the ETag the read returned, and so stays a conditional write. One
  # that comes back with no ETag has nothing to condition on, and the refused
  # `If-Match: *` guarded nothing, so it is replayed unconditionally as a 409
  # against the same header is.
  defp put_after_refused_wildcard(client, url, ical_data, policy, opts) do
    case fetch_document(client, url, opts) do
      {:ok, _document, etag} when is_binary(etag) and etag != "" ->
        Logger.info(
          "CalDAV server refused If-Match: * on an existing event, retrying under its ETag"
        )

        put(client, url, ical_data, etag, policy, opts)

      {:ok, _document, _no_etag} ->
        Logger.warning(
          "CalDAV server refused If-Match: * on an existing event, retrying unconditionally"
        )

        force_put(client, url, ical_data, opts)

      {:error, reason} when reason in [:not_found, :gone] ->
        Logger.info("CalDAV event absent on conditional update, reporting as not found")
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # :fail — surface the conflict to the caller.
  defp handle_precondition_failed(_client, _url, _ical, :fail, _opts),
    do: {:error, :precondition_failed}

  # :keep_server — silently accept the server's version; next sync will
  # refresh the local cache.
  defp handle_precondition_failed(_client, _url, _ical, :keep_server, _opts),
    do: :ok

  # :keep_local — force-overwrite by repeating the PUT unconditionally.
  defp handle_precondition_failed(client, url, ical_data, :keep_local, opts),
    do: force_put(client, url, ical_data, opts)

  # An overwrite carrying no conditional header at all. `If-Match: *` is not a
  # substitute: it still asserts the resource exists, so a server is entitled
  # to refuse it.
  defp force_put(client, url, ical_data, opts) do
    put_opts = Keyword.merge([operation: :force_update], Keyword.take(opts, [:timeout]))

    case Http.put_event(url, client.username, client.password, ical_data, put_opts) do
      {:ok, %Req.Response{status: status}} when status in [200, 201, 204] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The ETag to write under: the caller's cached one (`opts[:etag]`, from
  `provider_calendar_events.etag`), else whatever a HEAD probe finds, else
  the one a GET returns, else `nil`. The probe is for callers that do not
  know the current ETag, which includes every booking update.
  """
  @spec resolve_etag(String.t(), Base.client(), keyword()) :: String.t() | nil
  def resolve_etag(url, client, opts) do
    case Keyword.get(opts, :etag) do
      etag when is_binary(etag) and etag != "" -> etag
      _missing -> fetch_current_etag(url, client, opts)
    end
  end

  # HEAD is the cheap probe, but not every server answers it on an event
  # resource: iCloud returns 400 to the same URL it serves a GET on. A HEAD
  # that fails, or succeeds without an ETag, is followed by a GET, whose
  # response carries the ETag on those servers. Only a 404 or 410 settles that
  # there is nothing to read. Short timeout since the ETag is optional: a
  # probe that times out leaves the write to proceed without one.
  defp fetch_current_etag(url, client, opts) do
    head_timeout = Keyword.get(opts, :head_timeout, 15_000)
    head_opts = Keyword.put(opts, :timeout, head_timeout)

    case Http.head_event(url, client.username, client.password, head_opts) do
      {:ok, %{headers: headers}} -> etag_from_headers(headers) || etag_from_get(url, client, opts)
      {:error, reason} when reason in [:not_found, :gone] -> nil
      {:error, _reason} -> etag_from_get(url, client, opts)
    end
  end

  defp etag_from_get(url, client, opts) do
    case fetch_document(
           client,
           url,
           Keyword.put(opts, :read_timeout, Keyword.get(opts, :head_timeout, 15_000))
         ) do
      {:ok, _document, etag} -> etag
      {:error, _reason} -> nil
    end
  end

  @doc "The raw `ETag` response header, or `nil` when the server sent none."
  @spec etag_from_headers(map()) :: String.t() | nil
  def etag_from_headers(headers) do
    case Map.get(headers, "etag") do
      [etag | _rest] -> etag
      _other -> nil
    end
  end
end
