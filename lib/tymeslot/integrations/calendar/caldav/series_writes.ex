defmodule Tymeslot.Integrations.Calendar.CalDAV.SeriesWrites do
  @moduledoc """
  Writing part of a recurring event stored as one CalDAV resource: one
  occurrence deleted or edited, every occurrence edited, or the series split
  in two at an occurrence. The public entry points are
  `CalDAV.Events.delete_occurrence/4`, `update_occurrence/4`,
  `update_series/4` and `split_series/4`, which delegate here.

  `move_series/5` copies a whole series into another collection, on the same
  server or another, and deletes the original; it has no entry point on
  `CalDAV.Events`, since it needs two clients rather than one (see
  `Tymeslot.Integrations.Calendar.Events.move_caldav_series/4`).

  Each write rewrites the series' resource (see `ICalBuilder.Series`) and
  PUTs it back under `If-Match`: the cached document under its ETag when the
  cache holds both, else the server's copy, and on a 412 one re-read of the
  server's copy with the same rewrite applied to it (a split is made again
  whole from that copy, rather than ending it beside a tail split from the
  stale one). Always under the `:fail` policy: `:keep_local` would force a
  document built on a stale copy over a concurrent change, and
  `:keep_server` would report a change as made that is not on the calendar.
  """

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker

  alias Tymeslot.Integrations.Calendar.CalDAV.{
    Base,
    ConditionalWrite,
    Http,
    Scheduling,
    UrlBuilder
  }

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series
  alias Tymeslot.Utils.UriUtils

  require Logger

  # The answers to a conditional write that mean the resource changed since
  # the document it was made from was read.
  @stale [:precondition_failed, :conditional_not_supported]

  @typedoc "One occurrence of the series stored at `href`, keyed as the cache keys it."
  @type occurrence :: %{
          required(:href) => String.t(),
          required(:key) => String.t(),
          required(:timezone) => String.t() | nil,
          required(:document) => String.t() | nil,
          required(:etag) => String.t() | nil,
          optional(:changes) => map(),
          optional(:scope) => :this_only | :following | :all
        }

  @typedoc "The resource a split series' following occurrences were written to."
  @type tail :: %{uid: String.t(), href: String.t(), document: String.t()}

  @typedoc "The series a move copies: its resource, and the document and ETag the cache holds of it."
  @type source :: %{href: String.t(), document: String.t() | nil, etag: String.t() | nil}

  @typedoc "Where a moved series now lives."
  @type moved :: %{
          uid: String.t(),
          href: String.t(),
          calendar_path: String.t(),
          source: :removed | :left_behind
        }

  @doc """
  Moves the series stored at `source.href` on `source_client`'s server into
  the collection `calendar_path` on `destination_client`'s, which may be
  another server with other credentials. Every request goes out on the
  client of the server it addresses.

  The series is copied first, the document as it stands (the cached one
  when the cache holds it with its ETag, else the server's copy) under a
  fresh `UID` on the master and every override (`ICalBuilder.Series.reuid/2`),
  created as `<calendar_path><uid>.ics` under `If-None-Match: *`. Only once
  the destination has accepted it is the original deleted, under `If-Match`
  with the ETag the copy was made from, so a series changed in the meantime
  is not deleted unseen. A delete refused for that reason means the copy is
  stale: it is deleted from the destination again, and the move is made
  once more from the server's copy. Refused a second time, the move is
  `{:error, :precondition_failed}` with nothing moved.

  `calendar_path` must be one of the destination's writable collections,
  else `{:error, :no_destination_calendar}` before anything is sent. A copy
  the destination refuses is `{:error, reason}` with nothing written, and
  the original is not touched. A delete that fails otherwise once the copy
  is made, or a stale copy that cannot be deleted again, is not an error:
  the answer says `source: :left_behind`, the copy stays, and nothing is
  queued.
  """
  @spec move_series(Base.client(), Base.client(), source(), String.t(), keyword()) ::
          {:ok, moved()} | {:error, term()}
  def move_series(source_client, destination_client, source, calendar_path, opts \\ []) do
    with {:ok, collection} <- writable_collection(destination_client, calendar_path),
         {:ok, source_url} <- event_url(source_client, nil, source.href) do
      clients = {source_client, destination_client}
      copy_then_delete(clients, source_url, source, collection, opts, true)
    end
  end

  # The copy is made from the document the cache holds, so the happy path
  # reads nothing first; the delete under that document's ETag is what
  # notices a series changed since. That copy is stale, so it is deleted
  # again and the move made once more from the server's copy, as a split is
  # (`split_and_write/6`). A second refusal is reported rather than chased,
  # with nothing moved. Only a copy that cannot be taken back again stays,
  # beside the original (`:left_behind`).
  defp copy_then_delete(clients, source_url, source, collection, opts, retry?) do
    {source_client, destination_client} = clients

    with {:ok, document, etag} <- series_document(source_client, source_url, source, opts),
         {:ok, copy} <- copy(document),
         {:ok, created} <- create_copy(destination_client, collection, copy, opts) do
      moved = fn outcome ->
        {:ok, %{uid: created.uid, href: created.href, calendar_path: collection, source: outcome}}
      end

      case delete_original(source_client, source_url, etag, opts) do
        :removed ->
          moved.(:removed)

        {:stale, reason} ->
          case {discard_copy(destination_client, created, opts), retry?} do
            {:ok, true} ->
              copy_then_delete(clients, source_url, fresh(source), collection, opts, false)

            {:ok, false} ->
              {:error, reason}

            {:kept, _retry?} ->
              moved.(:left_behind)
          end

        :failed ->
          moved.(:left_behind)
      end
    end
  end

  defp fresh(source), do: %{source | document: nil, etag: nil}

  # The destination's own spelling of the collection, and only one it lists
  # as writable: the path arrives from the caller, and is a URL taken from a
  # payload until it has matched one.
  defp writable_collection(client, calendar_path) do
    case Enum.find(client.writable_calendar_paths, &UriUtils.uri_safe_match?(&1, calendar_path)) do
      nil -> {:error, :no_destination_calendar}
      collection -> {:ok, collection}
    end
  end

  # The breaker passes two-element answers through, so the pair travels
  # through it as one.
  defp series_document(client, url, source, opts) do
    result =
      with_breaker(client, opts, fn ->
        case starting_copy(client, url, source, opts) do
          {:ok, document, etag} -> {:ok, {document, etag}}
          other -> other
        end
      end)

    case result do
      {:ok, {document, etag}} -> {:ok, document, etag}
      {:ok, :gone} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy(document) do
    uid = Format.generate_uid()

    case Series.reuid(document, uid) do
      {:ok, copy} -> {:ok, %{tail: copy, tail_uid: uid}}
      :empty -> {:error, :not_found}
    end
  end

  defp create_copy(client, collection, copy, opts) do
    url = UrlBuilder.build_event_url(client.base_url, collection, copy.tail_uid)

    with {:ok, created} <-
           with_breaker(client, opts, fn -> create_tail(client, url, copy, opts) end),
         do: {:ok, Map.put(created, :url, url)}
  end

  defp delete_original(client, url, etag, opts) do
    delete_opts = Keyword.merge(timeout(opts), if_match: etag)

    result =
      with_breaker(client, opts, fn ->
        Http.delete_event(url, client.username, client.password, delete_opts)
      end)

    case result do
      {:ok, %Req.Response{}} -> :removed
      {:error, reason} when reason in @stale -> {:stale, reason}
      {:error, _reason} -> :failed
    end
  end

  # The copy of a series whose original could not be deleted because it
  # changed since the copy was made.
  defp discard_copy(client, created, opts) do
    result =
      with_breaker(client, opts, fn ->
        Http.delete_event(created.url, client.username, client.password, timeout(opts))
      end)

    case result do
      {:ok, %Req.Response{}} ->
        :ok

      {:error, reason} ->
        Logger.warning("CalDAV series move could not take back a copy made from a stale series",
          copy_url: created.url,
          reason: LogFormat.reason(reason)
        )

        :kept
    end
  end

  @doc "See `CalDAV.Events.delete_occurrence/4`."
  @spec delete_occurrence(Base.client(), String.t() | nil, occurrence(), keyword()) ::
          {:ok, %{document: String.t() | nil}} | {:error, term()}
  def delete_occurrence(client, calendar_path, occurrence, opts) do
    exclude = &Series.exclude_occurrence(&1, occurrence.key, occurrence.timezone)

    case rewrite_series(client, calendar_path, occurrence, exclude, opts) do
      # The whole series is already gone, and the occurrence with it.
      {:ok, :gone} -> {:ok, %{document: nil}}
      result -> result
    end
  end

  @doc "See `CalDAV.Events.update_occurrence/4`."
  @spec update_occurrence(Base.client(), String.t() | nil, occurrence(), keyword()) ::
          {:ok, %{document: String.t()}} | {:error, term()}
  def update_occurrence(client, calendar_path, %{changes: changes} = occurrence, opts) do
    mode = Scheduling.attendee_mode(client)
    override = &Series.put_override(&1, occurrence.key, changes, occurrence.timezone, mode)

    case rewrite_series(client, calendar_path, occurrence, override, opts) do
      {:ok, :gone} -> {:error, :not_found}
      result -> result
    end
  end

  @doc "See `CalDAV.Events.update_series/4`."
  @spec update_series(Base.client(), String.t() | nil, occurrence(), keyword()) ::
          {:ok, %{document: String.t()}} | {:error, term()}
  def update_series(client, calendar_path, %{changes: changes} = occurrence, opts) do
    mode = Scheduling.attendee_mode(client)
    edit = &Series.edit_master(&1, occurrence.key, changes, occurrence.timezone, mode)

    case rewrite_series(client, calendar_path, occurrence, edit, opts) do
      {:ok, :gone} -> {:error, :not_found}
      result -> result
    end
  end

  @doc "See `CalDAV.Events.split_series/4`."
  @spec split_series(Base.client(), String.t() | nil, occurrence(), keyword()) ::
          {:ok, %{document: String.t(), tail: tail()}}
          | {:ok, %{document: String.t()}}
          | {:error, term()}
  def split_series(client, calendar_path, %{href: href, changes: changes} = occurrence, opts) do
    mode = Scheduling.attendee_mode(client)
    split = &Series.split(&1, occurrence.key, changes, occurrence.timezone, mode)

    result =
      with_breaker(client, opts, fn ->
        with {:ok, url} <- event_url(client, calendar_path, href) do
          split_and_write(client, url, occurrence, split, opts)
        end
      end)

    case result do
      {:ok, :first_occurrence} -> update_series(client, calendar_path, occurrence, opts)
      other -> refusal_to_error(other)
    end
  end

  # Both halves are made from one document. A head the server refuses
  # because the series changed since that document was read has its tail
  # deleted, and the whole split is made again, once, from the server's copy:
  # ending the server's copy beside a tail split from the stale one would
  # bring back what was changed meanwhile from the split on. A second
  # refusal is reported rather than chased.
  defp split_and_write(client, url, occurrence, split, opts, retry? \\ true) do
    with {:ok, document, etag} <- starting_copy(client, url, occurrence, opts) do
      case split.(document) do
        {:ok, halves} ->
          head = %{occurrence | document: document, etag: etag}

          case create_tail_then_truncate(client, url, head, halves, opts) do
            {:error, reason} when retry? and reason in @stale ->
              fresh = %{occurrence | document: nil, etag: nil}
              split_and_write(client, url, fresh, split, opts, false)

            result ->
              result
          end

        :first_occurrence ->
          {:ok, :first_occurrence}

        {:error, reason} ->
          {:ok, {:refused, reason}}
      end
    end
  end

  # The tail is created first, so the following occurrences are never off
  # the calendar: if the head cannot be ended after it, the tail is deleted
  # again and the series stands as it was. `head` is the occurrence with the
  # document the split was made from and its ETag, which the head's write is
  # conditional on.
  defp create_tail_then_truncate(client, url, head, halves, opts) do
    tail_url = tail_url(url, halves.tail_uid)

    with {:ok, tail} <- create_tail(client, tail_url, halves, opts) do
      truncate = &Series.truncate(&1, head.key, head.timezone)

      case write_rewrite(client, url, head.document, head.etag, truncate, opts) do
        {:ok, %{document: document}} ->
          {:ok, %{document: document, tail: tail}}

        failure ->
          delete_tail(client, tail_url, opts)
          failure
      end
    end
  end

  defp delete_tail(client, tail_url, opts) do
    case Http.delete_event(tail_url, client.username, client.password, timeout(opts)) do
      {:ok, %Req.Response{}} ->
        :ok

      {:error, reason} ->
        Logger.warning("CalDAV series split left its following occurrences behind",
          tail_url: tail_url,
          reason: LogFormat.reason(reason)
        )
    end
  end

  # The tail goes into the series' own collection, beside it.
  defp tail_url(url, uid), do: String.replace(url, ~r{[^/]*$}, "") <> uid <> ".ics"

  defp create_tail(client, tail_url, halves, opts) do
    put_opts = Keyword.merge([operation: :create], timeout(opts))

    case Http.put_event(tail_url, client.username, client.password, halves.tail, put_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, %{uid: halves.tail_uid, href: href_path(tail_url), document: halves.tail}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp href_path(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _no_path -> url
    end
  end

  # The document the split is made from, with the ETag that makes the head's
  # write conditional: the cache's pair, or the server's copy.
  defp starting_copy(_client, _url, %{document: document, etag: etag}, _opts)
       when is_binary(document) and document != "" and is_binary(etag) and etag != "",
       do: {:ok, document, etag}

  defp starting_copy(client, url, _occurrence, opts) do
    case ConditionalWrite.fetch_document(client, url, opts) do
      {:ok, document, etag} -> {:ok, document, etag}
      {:error, reason} when reason in [:not_found, :gone] -> {:ok, :gone}
      {:error, reason} -> {:error, reason}
    end
  end

  # One rewrite of a series' resource: `fun` turns the document into the one
  # to PUT back (`{:ok, document}`), into nothing (`:empty`, which deletes the
  # resource), or refuses (`{:error, reason}`, and nothing is written).
  #
  # A refusal and a missing resource are answers about this series, not about
  # the host, so they travel back through the breaker as successes and only
  # become errors out here.
  defp rewrite_series(client, calendar_path, %{href: href} = occurrence, fun, opts) do
    result =
      with_breaker(client, opts, fn ->
        with {:ok, url} <- event_url(client, calendar_path, href) do
          rewrite_and_write(client, url, occurrence, fun, opts)
        end
      end)

    case result do
      {:ok, {:refused, reason}} -> {:error, reason}
      other -> other
    end
  end

  defp refusal_to_error({:ok, {:refused, reason}}), do: {:error, reason}
  defp refusal_to_error({:ok, :gone}), do: {:error, :not_found}
  defp refusal_to_error(other), do: other

  defp rewrite_and_write(client, url, %{document: document, etag: etag}, fun, opts)
       when is_binary(document) and document != "" and is_binary(etag) and etag != "" do
    case write_rewrite(client, url, document, etag, fun, opts) do
      {:error, reason} when reason in @stale ->
        refresh_and_rewrite(client, url, fun, opts)

      result ->
        result
    end
  end

  # Without a cached ETag the cached document carries no precondition, so the
  # server's copy, which comes with one, is read instead.
  defp rewrite_and_write(client, url, _occurrence, fun, opts),
    do: refresh_and_rewrite(client, url, fun, opts)

  # One re-read, one more PUT: a second 412 means the resource is still
  # changing under us, and is reported rather than chased.
  defp refresh_and_rewrite(client, url, fun, opts) do
    case ConditionalWrite.fetch_document(client, url, opts) do
      {:ok, document, etag} -> write_rewrite(client, url, document, etag, fun, opts)
      {:error, reason} when reason in [:not_found, :gone] -> {:ok, :gone}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_rewrite(client, url, document, etag, fun, opts) do
    case fun.(document) do
      {:ok, new_document} ->
        with :ok <- ConditionalWrite.put(client, url, new_document, etag, :fail, opts) do
          {:ok, %{document: new_document}}
        end

      :empty ->
        delete_resource(client, url, opts)

      {:error, reason} ->
        {:ok, {:refused, reason}}
    end
  end

  defp delete_resource(client, url, opts) do
    case Http.delete_event(url, client.username, client.password, timeout(opts)) do
      {:ok, %Req.Response{}} -> {:ok, %{document: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp timeout(opts), do: Keyword.take(opts, [:timeout])

  defp event_url(client, calendar_path, href),
    do: UrlBuilder.resolve_event_url(client.base_url, calendar_path, nil, href)

  defp with_breaker(client, opts, fun) do
    provider = Map.get(client, :provider, :caldav)
    opts = Keyword.put(opts, :host, Base.extract_host_from_url(client.base_url))
    CalendarCircuitBreaker.with_breaker(provider, opts, fun)
  end
end
