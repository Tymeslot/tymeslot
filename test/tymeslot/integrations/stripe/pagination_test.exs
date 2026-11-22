defmodule Tymeslot.Integrations.Stripe.PaginationTest do
  use ExUnit.Case, async: true

  alias Plug.Conn
  alias Plug.Conn.Query
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Stripe
  alias Tymeslot.Integrations.Stripe.Charges
  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Integrations.Stripe.Pagination

  @moduletag :payments

  @opts [api_key: "k"]

  @pages %{
    nil => %{"data" => [%{"id" => "ch_1"}, %{"id" => "ch_2"}], "has_more" => true},
    "ch_2" => %{"data" => [%{"id" => "ch_3"}, %{"id" => "ch_4"}], "has_more" => true},
    "ch_4" => %{"data" => [%{"id" => "ch_5"}], "has_more" => false}
  }

  # Serves `@pages` keyed by `starting_after`; `failing` pages answer 500.
  defp serve_pages(failing \\ []) do
    test_pid = self()

    ReqTest.stub(Stripe, fn conn ->
      query = Query.decode(conn.query_string)
      cursor = query["starting_after"]
      send(test_pid, {:page_request, query})

      if cursor in failing do
        conn |> Conn.put_status(500) |> ReqTest.json(%{"error" => %{"type" => "api_error"}})
      else
        ReqTest.json(conn, Map.fetch!(@pages, cursor))
      end
    end)
  end

  defp requested_queries(acc \\ []) do
    receive do
      {:page_request, query} -> requested_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "stream yields every object in order, paging by the last id" do
    serve_pages()

    ids =
      Enum.map(Pagination.stream(&Charges.list/2, %{customer: "cus_1"}, @opts), & &1["id"])

    assert ids == ["ch_1", "ch_2", "ch_3", "ch_4", "ch_5"]
    queries = requested_queries()
    assert Enum.map(queries, & &1["starting_after"]) == [nil, "ch_2", "ch_4"]
    assert Enum.map(queries, & &1["customer"]) == ["cus_1", "cus_1", "cus_1"]
  end

  test "limit defaults to 100 and a caller's limit is kept" do
    serve_pages()
    Enum.to_list(Pagination.stream(&Charges.list/2, %{}, @opts))
    assert Enum.uniq(Enum.map(requested_queries(), & &1["limit"])) == ["100"]

    Enum.to_list(Pagination.stream(&Charges.list/2, %{limit: 7}, @opts))
    assert Enum.uniq(Enum.map(requested_queries(), & &1["limit"])) == ["7"]
  end

  test "string-keyed params are accepted; a caller's limit and starting_after are honoured" do
    serve_pages()

    params = %{"limit" => 5, "starting_after" => "ch_2"}
    ids = Enum.map(Pagination.stream(&Charges.list/2, params, @opts), & &1["id"])

    assert ids == ["ch_3", "ch_4", "ch_5"]
    queries = requested_queries()
    assert Enum.map(queries, & &1["starting_after"]) == ["ch_2", "ch_4"]
    assert Enum.uniq(Enum.map(queries, & &1["limit"])) == ["5"]
  end

  test "has_more with no data ends the walk" do
    list_fun = fn _params, _opts -> {:ok, %{"data" => [], "has_more" => true}} end

    assert Enum.to_list(Pagination.stream(list_fun, %{}, [])) == []
    assert {:ok, []} = Pagination.collect(list_fun, %{}, [])
  end

  test "a response without data raises a clear error" do
    list_fun = fn _params, _opts -> {:ok, %{"object" => "list"}} end

    assert_raise ArgumentError, ~r/"data"/, fn -> Pagination.collect(list_fun, %{}, []) end
  end

  test "collect returns the objects" do
    serve_pages()
    assert {:ok, objects} = Pagination.collect(&Charges.list/2, %{}, @opts)
    assert length(objects) == 5
  end

  test "collect returns the error when a later page fails" do
    serve_pages(["ch_2"])

    assert {:error, %Error{status: 500}} = Pagination.collect(&Charges.list/2, %{}, @opts)
  end

  test "collect returns :missing_api_key instead of raising" do
    list_fun = fn _params, _opts -> {:error, :missing_api_key} end

    assert {:error, :missing_api_key} = Pagination.collect(list_fun, %{}, [])
  end

  test "stream raises ArgumentError for a reason that is not a Stripe error" do
    list_fun = fn _params, _opts -> {:error, :missing_api_key} end

    assert_raise ArgumentError, fn -> Enum.to_list(Pagination.stream(list_fun, %{}, [])) end
  end

  test "stream raises the error when a page fails" do
    serve_pages(["ch_2"])

    assert_raise Error, fn ->
      Enum.to_list(Pagination.stream(&Charges.list/2, %{}, @opts))
    end
  end

  test "stream is lazy" do
    serve_pages()

    assert [%{"id" => "ch_1"}] =
             Enum.take(Pagination.stream(&Charges.list/2, %{}, @opts), 1)

    assert length(requested_queries()) == 1
  end
end
