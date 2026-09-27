defmodule Tymeslot.Integrations.Calendar.Google.EventListing do
  @moduledoc """
  Walks a Google Calendar events listing to its last page.

  Every listing `Tymeslot.Integrations.Calendar.Google.CalendarAPI` makes goes
  through here: a windowed read of one calendar, the bootstrap, a sync-token
  delta, and the events of one series. They differ only in their base
  params, so they share one loop rather than holding copies of it: before
  PR #94 the incremental path had no pagination at all while bootstrap had it
  correct, and the windowed read of a secondary calendar kept only its first
  page until the sync began inferring deletions from what that read leaves
  out.

  `{:ok, _}` is only ever a complete listing: every page was read. A page
  that fails ends the walk with that page's error, and so does the page cap,
  so a caller never mistakes a truncated listing for the whole calendar.
  """

  require Logger

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI

  # Google's own maximum per page. Set here rather than by any caller, so the
  # page size cannot drift between listings again: the incremental path was
  # taking Google's default of 250 where bootstrap asked for 2500, about 18
  # sequential round-trips for a 4,465-event backlog where 2 would do.
  @max_results "2500"

  # No listing loop had any bound on iterations: a provider echoing the same
  # page token would occupy one of the ten `calendar_events` queue slots
  # permanently, with nothing in the logs to say why:
  # `SyncGoogleCalendarWorker` defines no `timeout/1`, so Oban's `:infinity`
  # default applies. At 2500 events a page this cap is far past any real
  # calendar, so hitting it means the provider is misbehaving, and saying so
  # beats looping in silence.
  @max_pages 200

  @type listing :: %{events: [map()], next_sync_token: String.t() | nil}

  @doc """
  Reads every page of the listing of `calendar_id` that `base_params`
  describe, with `token`.

  Each page goes through the Google circuit breaker unless `breaker: false`
  is given, for a caller that has never gone through it and handles errors
  without a `{:error, :circuit_open}` clause.
  """
  @spec fetch_all(String.t(), String.t(), map(), keyword()) ::
          {:ok, listing()} | {:error, :circuit_open} | {:error, atom(), String.t()} | term()
  def fetch_all(token, calendar_id, base_params, opts \\ []) do
    request =
      if Keyword.get(opts, :breaker, true),
        do: &CalendarCircuitBreaker.call(:google, &1),
        else: & &1.()

    fetch_page(request, token, calendar_id, base_params, nil, [], 1)
  end

  defp fetch_page(_request, _token, _calendar_id, _base_params, _page_token, _acc, page)
       when page > @max_pages do
    {:error, :too_many_pages,
     "Event listing exceeded #{@max_pages} pages of #{@max_results} events"}
  end

  defp fetch_page(request, token, calendar_id, base_params, page_token, acc, page) do
    params =
      base_params
      |> Map.put("maxResults", @max_results)
      |> maybe_put_page_token(page_token)

    result =
      request.(fn ->
        CalendarAPI.make_request(
          :get,
          "/calendars/#{URI.encode(calendar_id)}/events",
          token,
          params
        )
      end)

    case result do
      {:ok, response} when is_map(response) ->
        acc = Enum.reverse(response["items"] || [], acc)

        case response["nextPageToken"] do
          nil ->
            {:ok, %{events: Enum.reverse(acc), next_sync_token: response["nextSyncToken"]}}

          next_page ->
            fetch_page(request, token, calendar_id, base_params, next_page, acc, page + 1)
        end

      # Not an error tuple: the success clause is guarded on a map, so this
      # fires when `decode_body/1` decoded a JSON array or string rather than
      # an object, and the raw term is returned as the result. Preserved as it
      # has always behaved, but no longer silently.
      {:ok, body} ->
        Logger.warning("Google events listing returned a non-object body",
          calendar_id: calendar_id,
          body: inspect(body)
        )

        body

      {:error, :circuit_open} = error ->
        error

      # Load-bearing. The circuit breaker deliberately does not wrap the
      # calendar clients' 3-tuple, so a 410 arrives here as a bare
      # `{:error, :gone, "Resource no longer available"}`, which is exactly
      # what SyncGoogleCalendarWorker matches on to fall back to
      # `bootstrap_sync/1`. Unrecognised terms must pass through untouched.
      other ->
        other
    end
  end

  defp maybe_put_page_token(params, nil), do: params
  defp maybe_put_page_token(params, token), do: Map.put(params, "pageToken", token)
end
