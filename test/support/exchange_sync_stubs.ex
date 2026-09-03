defmodule Tymeslot.ExchangeSyncStubs do
  @moduledoc """
  The EWS stubbing an Exchange sync test needs, shared by the worker's two test
  modules.

  A sync run issues four different operations, and the free/busy read is sliced
  into one request per chunk of the sync window, so a positional stub answers
  the second slice with the wrong body. Everything here therefore dispatches on
  the request body rather than on call order.

  It lives in `test/support` rather than in one of the test modules because
  both of them drive a full run: one is about the two halves of the cache, the
  other about the incremental item read, and a second copy of the dispatch
  would drift the moment a new operation joined the cycle.
  """

  import ExUnit.Assertions

  alias Ecto.Changeset
  alias Oban.Testing, as: ObanTesting
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.ExchangeCase
  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncExchangeCalendarWorker

  @busy_start "2026-09-03T09:00:00Z"
  @busy_end "2026-09-03T10:00:00Z"

  @doc "The busy interval the default stub answers with."
  @spec default_interval() :: {String.t(), String.t()}
  def default_interval, do: {@busy_start, @busy_end}

  @doc """
  Answers every EWS operation a sync run issues, dispatching on the request
  body and forwarding each one to the calling process as `{:ews_request, body}`.

  `:intervals`, `:find_item`, `:get_item` and `:sync_folder_items` override
  what each operation is answered with.
  """
  @spec stub_full_sync(keyword()) :: :ok
  def stub_full_sync(opts \\ []) do
    responses = %{
      intervals: Keyword.get(opts, :intervals, [default_interval()]),
      find_item: Keyword.get(opts, :find_item, ExchangeFixtures.find_item_response()),
      get_item: Keyword.get(opts, :get_item, ExchangeFixtures.get_item_response()),
      sync_folder_items:
        Keyword.get(opts, :sync_folder_items, ExchangeFixtures.sync_folder_items_response())
    }

    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, request_body, conn} = Conn.read_body(conn)
      send(test_pid, {:ews_request, request_body})

      conn
      |> Conn.put_resp_content_type("text/xml")
      |> Conn.resp(200, ews_response(request_body, responses))
    end)
  end

  @doc "Runs one sync job for the integration."
  @spec run(struct()) :: term()
  def run(integration) do
    ObanTesting.perform_job(
      SyncExchangeCalendarWorker,
      %{"calendar_integration_id" => integration.id},
      repo: Repo
    )
  end

  @doc "The `display_only` rows the dashboard grid reads."
  @spec grid_rows(struct()) :: [struct()]
  def grid_rows(integration) do
    ProviderCalendarEventQueries.list_for_range([integration.id], window_start(), window_end())
  end

  @doc "The start of the sync window the worker uses."
  @spec window_start() :: DateTime.t()
  def window_start, do: DateTime.add(DateTime.utc_now(), -365, :day)

  @doc "The end of the sync window the worker uses."
  @spec window_end() :: DateTime.t()
  def window_end, do: DateTime.add(DateTime.utc_now(), 365, :day)

  @doc """
  Puts the last full item read far enough back that the worker forces another
  one, which is what the incremental path's staleness gate turns on.
  """
  @spec age_last_full_sync(struct()) :: struct()
  def age_last_full_sync(integration) do
    integration
    |> Changeset.change(%{last_full_sync_at: DateTime.add(DateTime.utc_now(:second), -2, :day)})
    |> Repo.update!()
  end

  @doc "Every request body sent since this was last called, in order."
  @spec sent_requests([String.t()]) :: [String.t()]
  def sent_requests(acc \\ []) do
    receive do
      {:ews_request, body} -> sent_requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ews_response(request_body, responses) do
    cond do
      request_body =~ "<m:GetUserAvailabilityRequest" ->
        availability_response(request_body, responses.intervals)

      request_body =~ "<m:FindItem" ->
        responses.find_item

      request_body =~ "<m:SyncFolderItems" ->
        responses.sync_folder_items

      request_body =~ "<m:GetItem" ->
        responses.get_item
    end
  end

  @doc """
  The free/busy body a server would answer the slice this request asked for.

  Public because a test stubbing the operations by hand still wants the
  clipping: a server answers a slice with the busy time inside *that* slice's
  window, so answering every slice with the whole fixture would report one
  meeting once per slice, and hide whether the right window was ever asked
  about.
  """
  @spec availability_response(String.t(), [{String.t(), String.t()}]) :: String.t()
  def availability_response(request_body, intervals) do
    {from, to} = ExchangeCase.requested_availability_window(request_body)

    ExchangeFixtures.availability_response(
      Enum.filter(intervals, fn {start_at, _end_at} ->
        assert {:ok, start_at, _offset} = DateTime.from_iso8601(start_at)

        DateTime.compare(start_at, from) != :lt and DateTime.compare(start_at, to) == :lt
      end)
    )
  end
end
