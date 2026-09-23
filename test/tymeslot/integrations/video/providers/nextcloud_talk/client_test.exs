defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.ClientTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client

  setup :verify_on_exit!

  @credentials %{
    base_url: "https://cloud.example.com/",
    client_id: "organiser",
    client_secret: "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
  }

  @room_api "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4/room"

  # Error bodies as Nextcloud 34 with Talk 24 sends them.
  @unauthorised ~s({"ocs":{"meta":{"status":"failure","statuscode":997,"message":"Unauthorised"},"data":[]}})
  @throttled ~s({"ocs":{"meta":{"status":"failure","statuscode":429,"message":"Reached maximum delay"},"data":[]}})
  @password_required ~s({"ocs":{"meta":{"status":"failure","statuscode":400,"message":""},"data":{"error":"password","message":"Password needs to be set"}}})

  describe "requests" do
    test "sign in with the login name and app password and carry the OCS headers" do
      expect(HTTPClientMock, :request, fn :get, url, "", headers, opts ->
        assert url == "https://cloud.example.com/ocs/v2.php/cloud/capabilities"

        assert {"Authorization",
                "Basic " <> Base.encode64("organiser:Abcde-Fghij-Klmno-Pqrst-Uvwxy")} in headers

        assert {"OCS-APIRequest", "true"} in headers
        assert {"Accept", "application/json"} in headers
        assert opts[:ssrf_protect] == true
        assert opts[:receive_timeout] == 15_000
        assert opts[:connect_options][:timeout] == 5_000

        {:ok, %Req.Response{status: 200, body: ocs(%{"capabilities" => %{}})}}
      end)

      assert {:ok, %{"capabilities" => %{}}} = Client.capabilities(@credentials)
    end

    # The capabilities endpoint answers an anonymous request in full, so the
    # account endpoint is what shows whether the credentials arrived.
    test "read the signed-in user's own account" do
      expect(HTTPClientMock, :request, fn :get, url, "", headers, _opts ->
        assert url == "https://cloud.example.com/ocs/v2.php/cloud/user"

        assert {"Authorization",
                "Basic " <> Base.encode64("organiser:Abcde-Fghij-Klmno-Pqrst-Uvwxy")} in headers

        {:ok, %Req.Response{status: 200, body: ocs(%{"id" => "organiser"})}}
      end)

      assert {:ok, %{"id" => "organiser"}} = Client.user(@credentials)
    end

    test "list the signed-in user's conversations without their last messages" do
      expect(HTTPClientMock, :request, fn :get, url, "", headers, opts ->
        assert url == @room_api <> "?noStatusUpdate=1&includeLastMessage=0"
        refute List.keymember?(headers, "Content-Type", 0)
        assert opts[:ssrf_protect] == true

        {:ok,
         %Req.Response{status: 200, body: ocs([%{"token" => "abc123xy", "description" => ""}])}}
      end)

      assert {:ok, [%{"token" => "abc123xy"}]} = Client.list_rooms(@credentials)
    end

    test "declare the budget of one request from the options every request is sent with, capping the whole response" do
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, opts ->
        # A cap on the whole response is what makes the budget a real bound.
        assert is_integer(opts[:request_timeout])
        assert Client.request_budget_ms(:post) == HTTPClient.request_budget_ms(:post, opts)

        {:ok, %Req.Response{status: 201, body: ocs(%{"token" => "abc123xy"})}}
      end)

      assert {:ok, _data} = Client.create_room(@credentials, %{"roomType" => 3})
    end

    test "create a conversation from a JSON body and return its data" do
      expect(HTTPClientMock, :request, fn :post, url, body, headers, _opts ->
        assert url == @room_api
        assert {"Content-Type", "application/json"} in headers
        assert Jason.decode!(body) == %{"roomType" => 3, "roomName" => "Intro call"}

        {:ok, %Req.Response{status: 201, body: ocs(%{"token" => "abc123xy"})}}
      end)

      assert {:ok, %{"token" => "abc123xy"}} =
               Client.create_room(@credentials, %{"roomType" => 3, "roomName" => "Intro call"})
    end

    test "move the lobby, rename and delete a conversation by its token" do
      expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy/webinar/lobby"
        assert Jason.decode!(body) == %{"state" => 1, "timer" => 1_800_000_000}
        {:ok, %Req.Response{status: 200, body: ocs(room(%{"lobbyTimer" => 1_800_000_000}))}}
      end)

      expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy"
        assert Jason.decode!(body) == %{"roomName" => "Moved call"}
        {:ok, %Req.Response{status: 200, body: ocs(room(%{"name" => "Moved call"}))}}
      end)

      # Talk answers a deletion with `data: null`.
      expect(HTTPClientMock, :request, fn :delete, url, "", _headers, _opts ->
        assert url == @room_api <> "/abc123xy"
        {:ok, %Req.Response{status: 200, body: ocs(nil)}}
      end)

      assert {:ok, %{"lobbyTimer" => 1_800_000_000}} =
               Client.set_lobby(@credentials, "abc123xy", %{
                 "state" => 1,
                 "timer" => 1_800_000_000
               })

      assert {:ok, %{"name" => "Moved call"}} =
               Client.rename_room(@credentials, "abc123xy", "Moved call")

      assert {:ok, nil} = Client.delete_room(@credentials, "abc123xy")
    end
  end

  describe "conversation tokens" do
    test "valid_token?/1 accepts only Talk's route format" do
      assert Client.valid_token?("abc123xy")
      assert Client.valid_token?("abcd")
      assert Client.valid_token?(String.duplicate("a", 30))

      invalid = ["abc", String.duplicate("a", 31), "ABC123xy", "abc-123x", "abc123xy\n", nil]
      assert Enum.filter(invalid, &Client.valid_token?/1) == []
    end

    test "a token outside Talk's route format is refused before any request" do
      # No expectation is set, so any request would fail the test with
      # Mox.UnexpectedCallError.
      tokens = ["..", "", "abc 123xy", "ABC123xy", "abc", "abc123xy/../users", "abc%2F123"]

      assert Enum.reject(
               tokens,
               &(Client.delete_room(@credentials, &1) == {:error, :invalid_token})
             ) ==
               []

      assert Enum.reject(
               tokens,
               &(Client.rename_room(@credentials, &1, "Call") == {:error, :invalid_token})
             ) ==
               []

      assert Enum.reject(
               tokens,
               &(Client.set_lobby(@credentials, &1, %{"state" => 0}) == {:error, :invalid_token})
             ) ==
               []
    end
  end

  describe "response classification" do
    test "a 401 is a refused credential" do
      assert {:error, :unauthorized} = respond_with(status: 401, body: @unauthorised)
    end

    test "a 404 is not found" do
      assert {:error, :not_found} = respond_with(status: 404, body: failure(404, []))
    end

    test "a redirect is reported with its target and never followed" do
      assert {:error, {:redirected, "https://cloud.example.com/login"}} =
               respond_with(
                 status: 302,
                 headers: %{"location" => ["https://cloud.example.com/login"]},
                 body: ""
               )
    end

    test "a 400 carries the OCS error key" do
      assert {:error, {:rejected, 400, "password"}} =
               respond_with(status: 400, body: @password_required)
    end

    test "a 403 Talk worded without an error key is still a rejection" do
      assert {:error, {:rejected, 403, nil}} =
               respond_with(status: 403, body: failure(403, [], "Can not use Talk"))
    end

    test "a redirect without a location is still reported" do
      assert {:error, {:redirected, nil}} = respond_with(status: 302, body: "")
    end

    # A page from a proxy in front of Nextcloud says nothing about Talk, so it
    # is the HTTP error it is rather than a refusal the provider would read.
    test "a 400 whose body is not the OCS envelope is an HTTP error" do
      assert {:error, {:http_error, 400}} =
               respond_with(status: 400, body: "<html><body>Bad Request</body></html>")
    end

    test "a 403 whose body is not the OCS envelope is an HTTP error" do
      assert {:error, {:http_error, 403}} =
               respond_with(status: 403, body: "<html><body>Access denied</body></html>")
    end

    test "a 429 is a rate limit, not a server error" do
      assert {:error, :rate_limited} = respond_with(status: 429, body: @throttled)
    end

    test "a server error keeps its status" do
      assert {:error, {:http_error, 503}} = respond_with(status: 503, body: "")
    end

    test "a success that is not the OCS envelope is an invalid response" do
      assert {:error, :invalid_response} = respond_with(status: 200, body: "<html></html>")
    end

    test "a success with an empty body is an invalid response" do
      assert {:error, :invalid_response} = respond_with(status: 200, body: "")
    end

    test "no error result carries the app password or the Authorization header" do
      results = [
        respond_with(status: 401, body: @unauthorised),
        respond_with(status: 404, body: failure(404, [])),
        respond_with(status: 302, headers: %{"location" => ["https://cloud.example.com/login"]}),
        respond_with(status: 400, body: @password_required),
        respond_with(status: 429, body: @throttled),
        respond_with(status: 503, body: ""),
        respond_with(status: 200, body: "<html></html>"),
        Client.delete_room(@credentials, "..")
      ]

      basic = Base.encode64("organiser:Abcde-Fghij-Klmno-Pqrst-Uvwxy")

      assert Enum.filter(
               results,
               &(inspect(&1) =~ @credentials.client_secret or inspect(&1) =~ basic)
             ) ==
               []

      assert Enum.all?(results, &match?({:error, _reason}, &1))
    end

    test "a transport failure passes through untouched" do
      failure = %Req.TransportError{reason: :econnrefused}

      expect(HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:error, failure}
      end)

      assert {:error, ^failure} = Client.capabilities(@credentials)
    end
  end

  defp respond_with(fields) do
    response = struct(Req.Response, fields)

    expect(HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
      {:ok, response}
    end)

    Client.capabilities(@credentials)
  end

  defp ocs(data) do
    Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
  end

  defp failure(status, data, message \\ "") do
    Jason.encode!(%{
      "ocs" => %{
        "meta" => %{"status" => "failure", "statuscode" => status, "message" => message},
        "data" => data
      }
    })
  end

  # The fields of Talk's conversation object that these tests read.
  defp room(fields) do
    Map.merge(
      %{"token" => "abc123xy", "type" => 3, "name" => "Intro call", "lobbyState" => 1},
      fields
    )
  end
end
