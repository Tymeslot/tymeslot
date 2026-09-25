defmodule Tymeslot.Integrations.Calendar.CalDAV.SeriesWrites do
  @moduledoc """
  Writing part of a recurring event stored as one CalDAV resource: one
  occurrence deleted or edited, every occurrence edited, or the series split
  in two at an occurrence. The public entry points are
  `CalDAV.Events.delete_occurrence/4`, `update_occurrence/4`,
  `update_series/4` and `split_series/4`, which delegate here.

  Each write rewrites the series' resource (see `ICalBuilder.Series`) and
  PUTs it back under `If-Match`: the cached document under its ETag when the
  cache holds both, else the server's copy, and on a 412 one re-read of the
  server's copy with the same rewrite applied to it. Always under the
  `:fail` policy: `:keep_local` would force a document built on a stale copy
  over a concurrent change, and `:keep_server` would report a change as made
  that is not on the calendar.
  """

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker

  alias Tymeslot.Integrations.Calendar.CalDAV.{
    Base,
    ConditionalWrite,
    Http,
    Scheduling,
    UrlBuilder
  }

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series

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

  defp split_and_write(client, url, occurrence, split, opts) do
    with {:ok, document, etag} <- starting_copy(client, url, occurrence, opts) do
      case split.(document) do
        {:ok, halves} ->
          head = %{occurrence | document: document, etag: etag}
          create_tail_then_truncate(client, url, head, halves, opts)

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
  # document the split was made from and its ETag; the head is ended by the
  # rewrite loop, so a 412 ends the server's copy instead.
  defp create_tail_then_truncate(client, url, head, halves, opts) do
    tail_url = tail_url(url, halves.tail_uid)

    with {:ok, tail} <- create_tail(client, tail_url, halves, opts) do
      truncate = &Series.truncate(&1, head.key, head.timezone)

      case rewrite_and_write(client, url, head, truncate, opts) do
        {:ok, %{document: document}} ->
          {:ok, %{document: document, tail: tail}}

        failure ->
          _deleted = Http.delete_event(tail_url, client.username, client.password, timeout(opts))
          failure
      end
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
      {:error, reason} when reason in [:precondition_failed, :conditional_not_supported] ->
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
