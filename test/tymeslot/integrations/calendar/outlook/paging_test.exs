defmodule Tymeslot.Integrations.Calendar.Outlook.PagingTest do
  @moduledoc """
  Every multi-page Graph read follows the links Graph returns exactly as
  they came, reads every page or fails, and stops at one cap.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Mox

  alias Tymeslot.Integrations.Calendar.Outlook.Paging

  setup :verify_on_exit!

  @next "https://graph.microsoft.com/v1.0/me/calendarView/delta?$skiptoken=page%2B2"
  @delta "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"

  defp page(body), do: {:ok, %Req.Response{status: 200, body: Jason.encode!(body)}}

  defp prefer(headers) do
    Enum.find_value(headers, fn {name, value} -> if name == "Prefer", do: value end)
  end

  describe "a delta read" do
    test "follows the next link verbatim to the delta link, reading every page" do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, headers, _opts ->
        send(test_pid, {:requested, url, prefer(headers)})

        if url =~ "skiptoken",
          do: page(%{"value" => [%{"id" => "b"}], "@odata.deltaLink" => @delta}),
          else: page(%{"value" => [%{"id" => "a"}], "@odata.nextLink" => @next})
      end)

      assert {:ok, [%{"id" => "a"}, %{"id" => "b"}], @delta} =
               Paging.delta_all(
                 "token",
                 {:start, "/me/calendarView/delta", %{"startDateTime" => "x"}}
               )

      assert_received {:requested, first, first_prefer}
      assert first =~ "/v1.0/me/calendarView/delta?startDateTime=x"
      assert first_prefer =~ "odata.maxpagesize="

      # Decoding and re-encoding would have sent `%24skiptoken` and a
      # literal `+`: Graph rejects the first and misreads the second.
      assert_received {:requested, @next, second_prefer}
      assert second_prefer =~ "odata.maxpagesize="
    end

    test "drops the query parameters Graph refuses from a stored link" do
      stored = @delta <> "&$select=subject&$top=5"

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert url == @delta <> "&$top=5"
        page(%{"value" => [], "@odata.deltaLink" => @delta})
      end)

      assert {:ok, [], @delta} = Paging.delta_all("token", {:link, stored})
    end

    test "a link Graph no longer honours is :delta_link_expired" do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 410, body: ""}}
      end)

      assert {:error, :delta_link_expired, _message} = Paging.delta_all("token", {:link, @delta})
    end
  end

  describe "the page cap" do
    setup do
      stub(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        page(%{"value" => [%{"id" => "x"}], "@odata.nextLink" => @next})
      end)

      :ok
    end

    test "ends a delta read that never reaches its delta link" do
      assert {:error, :too_many_pages, _message} = Paging.delta_all("token", {:link, @delta})
    end

    test "ends a list read with the same answer, never a part of the list" do
      assert {:error, :too_many_pages, _message} =
               Paging.list_all("token", "/me/calendars", %{})
    end
  end

  test "a list read ends at the page with no next link" do
    expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, headers, _opts ->
      refute prefer(headers) =~ "maxpagesize"

      if url =~ "skiptoken",
        do: page(%{"value" => [%{"id" => "2"}]}),
        else: page(%{"value" => [%{"id" => "1"}], "@odata.nextLink" => @next})
    end)

    assert {:ok, [%{"id" => "1"}, %{"id" => "2"}]} =
             Paging.list_all("token", "/me/calendars", %{"$top" => "1000"})
  end
end
