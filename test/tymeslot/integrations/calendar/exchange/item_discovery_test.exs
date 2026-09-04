defmodule Tymeslot.Integrations.Calendar.Exchange.ItemDiscoveryTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import Tymeslot.ExchangeCase, only: [response_envelope: 2]

  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Integrations.Calendar.Exchange.ItemDiscovery
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  describe "item_ids/1" do
    test "returns an id and change key pair for every calendar item listed" do
      {:ok, doc} =
        Soap.parse(ExchangeFixtures.find_item_response([{"item-1", "ck-1"}, {"item-2", "ck-2"}]))

      assert ItemDiscovery.item_ids(doc) == {:ok, [{"item-1", "ck-1"}, {"item-2", "ck-2"}]}
    end

    test "returns no ids for a window holding no events" do
      {:ok, doc} = Soap.parse(ExchangeFixtures.empty_find_item_response())

      assert ItemDiscovery.item_ids(doc) == {:ok, []}
    end

    test "drops an item id the server stated no Id attribute for" do
      # An id is what makes an item fetchable, so one without it cannot be put
      # in a `GetItem` batch: sending `<t:ItemId ChangeKey="ck-1"/>` faults the
      # whole batch, taking every readable item in the window with it.
      {:ok, doc} =
        Soap.parse(find_item([~s(<t:ItemId ChangeKey="ck-1"/>), ~s(<t:ItemId Id="b"/>)]))

      assert ItemDiscovery.item_ids(doc) == {:ok, [{"b", ""}]}
    end

    test "keeps an item the server stated no change key for, with an empty one" do
      # EWS treats the change key as optional, and a `GetItem` naming an id
      # alone is a valid request for the current version of that item. Dropping
      # the item instead would lose a real meeting from the grid.
      {:ok, doc} = Soap.parse(find_item(~s(<t:ItemId Id="item-1"/>)))

      assert ItemDiscovery.item_ids(doc) == {:ok, [{"item-1", ""}]}
    end

    test "surfaces a stated failure rather than an empty window" do
      # A failed message carries no `m:RootFolder`, so walking straight to the
      # ids answers `[]` for a folder that could not be read at all, which the
      # sync layer persists as an emptied calendar.
      {:ok, doc} = Soap.parse(ExchangeFixtures.failed_response("FindItem", "ErrorAccessDenied"))

      assert ItemDiscovery.item_ids(doc) == {:error, {:response_code, "ErrorAccessDenied"}}
    end

    test "reports a response carrying no FindItem message at all" do
      {:ok, doc} = Soap.parse(ExchangeFixtures.find_folder_response())

      assert ItemDiscovery.item_ids(doc) == {:error, :no_response_messages}
    end
  end

  # A `FindItem` response whose single message carries the given `t:ItemId`
  # elements, each wrapped in the `t:CalendarItem` a real response nests it in.
  defp find_item(item_ids) when is_binary(item_ids), do: find_item([item_ids])

  defp find_item(item_ids) do
    items = Enum.map_join(item_ids, "\n", &"<t:CalendarItem>#{&1}</t:CalendarItem>")

    response_envelope("FindItem", "<m:RootFolder><t:Items>#{items}</t:Items></m:RootFolder>")
  end
end
