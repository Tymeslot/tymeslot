defmodule Tymeslot.Integrations.Calendar.Exchange.ItemDiscovery do
  @moduledoc """
  Turns a `FindItem` response into the ids a batched `GetItem` is built from.

  `FindItem` is asked over a `CalendarView` with `BaseShape=IdOnly`, so ids are
  the whole of what it answers: it cannot return an item's iCalendar `UID` —
  the property is silently dropped rather than faulted — and a cached event
  needs a stable uid, which is why the fields come from a second round trip
  through `Exchange.EventNormaliser` rather than from here.

  ## A failed response message fails the walk

  The response code is read before the items are. A `FindItem` message that
  failed carries no `m:RootFolder`, so walking straight to the ids answers `[]`
  for a folder that could not be read at all — which the sync layer cannot tell
  from a genuinely empty window and persists as an emptied calendar.
  `Soap.require_success/2` surfaces the server's own code instead.

  ## Fetching the fields lives here too

  `fetch_items/2` is the second half of the same read: the batched `GetItem`
  the ids feed. It sits beside them because both callers of the item path need
  the pair — `Exchange.Provider.list_calendar_items/2` gets its ids from
  `FindItem` over a window, and `Exchange.ItemSync` gets them from a change
  feed — and a second copy of the batch-and-guard sequence in either would be
  a second place to remember that an all-failed batch must not read as an
  empty calendar.
  """

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Integrations.Calendar.Exchange.Client
  alias Tymeslot.Integrations.Calendar.Exchange.EventNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.Requests
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  # `GetItem` answers with `BaseShape=Default`, which carries each item's full
  # body, so one request for a whole window (up to the server's
  # `FindCountLimit`, 1000 by default) could run to tens of megabytes. A
  # hundred ids keeps every response comfortably inside the EWS byte budget.
  @get_item_batch_size 100

  @typedoc """
  An item id and the change key stating which version of it was seen. The
  change key is `""` where the server stated none.
  """
  @type id_pair :: {String.t(), String.t()}

  @doc """
  Extracts every calendar item id a parsed `FindItem` response carries.
  """
  @spec item_ids(Soap.document()) :: {:ok, [id_pair()]} | {:error, Soap.failure()}
  def item_ids(doc) do
    with {:ok, messages} <- Soap.require_success(doc, "FindItemResponseMessage") do
      {:ok, messages |> Enum.flat_map(&ids_in/1) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  Fetches the given items' fields with batched `GetItem` requests, at most
  #{@get_item_batch_size} ids to a request, answering the items in the order
  the ids were given.

  An empty list is answered `{:ok, []}` without a round trip: `m:ItemIds`
  demands a child, so an empty batch would be answered with a schema fault
  rather than an empty list. A batch answered over the response budget is
  split in half and retried, down to single items; any other failure, or one
  item over budget on its own, fails the whole read. No partial window is
  answered.

  Answers the raw `t:CalendarItem` elements, which
  `Exchange.EventNormaliser.normalise_events/2` turns into `CalendarEvent`
  structs. The batch-level guard is applied first, so a response in which
  every message failed is an error rather than an empty calendar, and so is
  one in which no item came back with the properties the request asked for.
  """
  @spec fetch_items(Client.config(), [id_pair()]) :: {:ok, [Soap.document()]} | {:error, term()}
  def fetch_items(_config, []), do: {:ok, []}

  def fetch_items(config, ids) do
    with {:ok, docs} <- fetch_batches(config, Enum.chunk_every(ids, @get_item_batch_size)),
         :ok <- EventNormaliser.require_readable_batch(docs),
         items = Enum.flat_map(docs, &EventNormaliser.parse_items/1),
         :ok <-
           EventNormaliser.require_requested_properties(
             items,
             Map.get(config, :calendar_integration_id)
           ) do
      {:ok, items}
    end
  end

  defp fetch_batches(config, batches) do
    fetched =
      Enum.reduce_while(batches, {:ok, []}, fn batch, {:ok, acc} ->
        case fetch_batch(config, batch) do
          {:ok, docs} -> {:cont, {:ok, [docs | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, acc} <- fetched, do: {:ok, acc |> Enum.reverse() |> Enum.concat()}
  end

  # A batch whose bodies outgrow the response budget is halved until each half
  # fits, so a few very large invitations cost extra round trips rather than
  # the whole read. Only a single item that is over budget on its own still
  # fails the read.
  defp fetch_batch(config, [_first, _second | _rest] = ids) do
    case Client.call(config, Requests.get_item(ids)) do
      {:error, :response_too_large} ->
        {left, right} = Enum.split(ids, div(length(ids), 2))

        with {:ok, left_docs} <- fetch_batch(config, left),
             {:ok, right_docs} <- fetch_batch(config, right) do
          {:ok, left_docs ++ right_docs}
        end

      other ->
        wrap(other)
    end
  end

  defp fetch_batch(config, ids), do: config |> Client.call(Requests.get_item(ids)) |> wrap()

  defp wrap({:ok, doc}), do: {:ok, [doc]}
  defp wrap({:error, _reason} = error), do: error

  defp ids_in(message) do
    message
    |> Soap.xpath(~x"./m:RootFolder/t:Items/t:CalendarItem/t:ItemId"l)
    |> Enum.map(&to_id_pair/1)
  end

  # An id is what makes an item fetchable, so one without it is dropped rather
  # than sent. The change key is not: EWS treats it as optional, and a
  # `GetItem` naming an id alone is a valid request for the current version of
  # that item, which is what a sync wants anyway.
  defp to_id_pair(item_id) do
    case Soap.text(item_id, ~x"./@Id") do
      nil -> nil
      id -> {id, Soap.text(item_id, ~x"./@ChangeKey") || ""}
    end
  end
end
