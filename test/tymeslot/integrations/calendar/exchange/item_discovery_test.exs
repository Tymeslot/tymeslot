defmodule Tymeslot.Integrations.Calendar.Exchange.ItemDiscoveryTest do
  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  @ews_budget 8 * 1024 * 1024

  import SweetXml, only: [sigil_x: 2]

  alias Plug.Conn
  alias Req.Test, as: ReqTest
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

  describe "fetch_items/2" do
    test "fetches a large window in batches of 100 ids, answering items in id order" do
      answer_get_item_with(fn ids -> Enum.map(ids, &{:ok, id: &1}) end)
      ids = for n <- 1..250, do: {"item-#{n}", "ck-#{n}"}

      assert {:ok, items} = ItemDiscovery.fetch_items(config(), ids)

      assert_received {:get_item, first}
      assert_received {:get_item, second}
      assert_received {:get_item, third}
      refute_received {:get_item, _}
      assert Enum.map([first, second, third], &length/1) == [100, 100, 50]
      assert first ++ second ++ third == Enum.map(ids, &elem(&1, 0))

      assert Enum.map(items, &Soap.text(&1, ~x"./t:ItemId/@Id")) == Enum.map(ids, &elem(&1, 0))
    end

    test "fails the whole read when one batch fails outright" do
      answer_get_item_with(fn ids ->
        if "item-150" in ids, do: :server_error, else: Enum.map(ids, &{:ok, id: &1})
      end)

      ids = for n <- 1..250, do: {"item-#{n}", "ck-#{n}"}

      assert {:error, _reason} = ItemDiscovery.fetch_items(config(), ids)
    end

    test "reads a window whose one batch lost every message while the others were answered" do
      # The all-failed refusal guards against an emptied calendar, which is a
      # verdict on the read as a whole: items deleted mid-sync can fill one
      # batch without the window being unreadable.
      answer_get_item_with(fn ids ->
        if "item-1" in ids,
          do: Enum.map(ids, &{:ok, id: &1}),
          else: Enum.map(ids, fn _id -> {:error, "ErrorItemNotFound"} end)
      end)

      ids = for n <- 1..150, do: {"item-#{n}", "ck-#{n}"}

      assert {:ok, items} = ItemDiscovery.fetch_items(config(), ids)
      assert length(items) == 100
    end

    test "halves a batch the response budget refuses until each part fits" do
      # Bodies large enough to outgrow the budget whenever item-7 shares a
      # request with more than eleven others.
      answer_get_item_with(fn ids ->
        if "item-7" in ids and length(ids) > 12,
          do: :too_large,
          else: Enum.map(ids, &{:ok, id: &1})
      end)

      ids = for n <- 1..150, do: {"item-#{n}", "ck-#{n}"}

      assert {:ok, items} = ItemDiscovery.fetch_items(config(), ids)

      assert Enum.map(received_get_items(), &length/1) == [100, 50, 25, 12, 13, 25, 50, 50]
      assert Enum.map(items, &Soap.text(&1, ~x"./t:ItemId/@Id")) == Enum.map(ids, &elem(&1, 0))
    end

    test "fails the read when a single item is over the response budget on its own" do
      answer_get_item_with(fn ids ->
        if "item-7" in ids, do: :too_large, else: Enum.map(ids, &{:ok, id: &1})
      end)

      ids = for n <- 1..150, do: {"item-#{n}", "ck-#{n}"}

      assert ItemDiscovery.fetch_items(config(), ids) == {:error, :response_too_large}
      assert List.last(received_get_items()) == ["item-7"]
    end

    test "refuses a read in which every message of every batch failed" do
      answer_get_item_with(fn ids ->
        Enum.map(ids, fn _id -> {:error, "ErrorAccessDenied"} end)
      end)

      ids = for n <- 1..150, do: {"item-#{n}", "ck-#{n}"}

      assert ItemDiscovery.fetch_items(config(), ids) ==
               {:error, {:response_code, "ErrorAccessDenied"}}
    end

    # A server that ignored `t:AdditionalProperties` would answer bare ids under
    # `NoError`, every item would then fail normalisation, and the read would
    # look like an empty calendar.
    test "refuses a read whose items came back without the requested properties" do
      answer_get_item_with(fn ids -> Enum.map(ids, &{:ok, id: &1, id_only: true}) end)

      ids = for n <- 1..3, do: {"item-#{n}", "ck-#{n}"}

      assert ItemDiscovery.fetch_items(config(), ids) == {:error, :item_properties_missing}
    end

    # One unusable item is not the ignored-properties signature: it is
    # skipped and reported on its own when the items are normalised.
    test "answers a read in which only some items lack the requested properties" do
      answer_get_item_with(fn ids ->
        Enum.map(ids, fn
          "item-2" = id -> {:ok, id: id, id_only: true}
          id -> {:ok, id: id}
        end)
      end)

      ids = for n <- 1..3, do: {"item-#{n}", "ck-#{n}"}

      assert {:ok, items} = ItemDiscovery.fetch_items(config(), ids)
      assert Enum.map(items, &Soap.text(&1, ~x"./t:ItemId/@Id")) == Enum.map(ids, &elem(&1, 0))
    end
  end

  # Answers each `GetItem` with the messages `entries_for` builds from the ids
  # it names (a 500 for `:server_error`, a body one byte over the EWS budget
  # for `:too_large`), and reports those ids to the test process in request
  # order.
  defp answer_get_item_with(entries_for) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)

      ids =
        ~r/<t:ItemId Id="([^"]+)"/ |> Regex.scan(body, capture: :all_but_first) |> List.flatten()

      send(test_pid, {:get_item, ids})

      case entries_for.(ids) do
        :server_error ->
          Conn.resp(conn, 500, "")

        :too_large ->
          conn
          |> Conn.put_resp_content_type("text/xml")
          |> Conn.resp(200, String.duplicate(" ", @ews_budget + 1))

        entries ->
          conn
          |> Conn.put_resp_content_type("text/xml")
          |> Conn.resp(200, ExchangeFixtures.get_item_batch_response(entries))
      end
    end)
  end

  defp received_get_items(acc \\ []) do
    receive do
      {:get_item, ids} -> received_get_items([ids | acc])
    after
      0 -> Enum.reverse(acc)
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
