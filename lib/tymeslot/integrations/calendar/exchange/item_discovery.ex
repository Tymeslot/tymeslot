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
  Fetches the given items' fields in one batched `GetItem`.

  An empty list is answered `{:ok, []}` without a round trip: `m:ItemIds`
  demands a child, so an empty batch would be answered with a schema fault
  rather than an empty list.

  Answers the raw `t:CalendarItem` elements, which
  `Exchange.EventNormaliser.normalise_events/2` turns into `CalendarEvent`
  structs. The batch-level guard is applied first, so a response in which
  every message failed is an error rather than an empty calendar.
  """
  @spec fetch_items(Client.config(), [id_pair()]) :: {:ok, [Soap.document()]} | {:error, term()}
  def fetch_items(_config, []), do: {:ok, []}

  def fetch_items(config, ids) do
    with {:ok, doc} <- Client.call(config, Requests.get_item(ids)),
         :ok <- EventNormaliser.require_readable_batch(doc) do
      {:ok, EventNormaliser.parse_items(doc)}
    end
  end

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
