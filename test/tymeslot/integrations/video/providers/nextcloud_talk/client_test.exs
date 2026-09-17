defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.ClientTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client

  setup :verify_on_exit!

  @credentials %{
    base_url: "https://cloud.example.com/",
    client_id: "organiser",
    client_secret: "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
  }

  @room_api "https://cloud.example.com/ocs/v2.php/apps/spreed/api/v4/room"

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
        {:ok, %Req.Response{status: 200, body: ocs(%{})}}
      end)

      expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert url == @room_api <> "/abc123xy"
        assert Jason.decode!(body) == %{"roomName" => "Moved call"}
        {:ok, %Req.Response{status: 200, body: ocs([])}}
      end)

      expect(HTTPClientMock, :request, fn :delete, url, "", _headers, _opts ->
        assert url == @room_api <> "/abc123xy"
        {:ok, %Req.Response{status: 200, body: ocs([])}}
      end)

      assert {:ok, _data} =
               Client.set_lobby(@credentials, "abc123xy", %{
                 "state" => 1,
                 "timer" => 1_800_000_000
               })

      assert {:ok, _data} = Client.rename_room(@credentials, "abc123xy", "Moved call")
      assert {:ok, _data} = Client.delete_room(@credentials, "abc123xy")
    end
  end

  describe "conversation tokens" do
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
      assert {:error, :unauthorized} = respond_with(status: 401, body: "")
    end

    test "a 404 is not found" do
      assert {:error, :not_found} = respond_with(status: 404, body: ocs(nil))
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
               respond_with(status: 400, body: ocs(%{"error" => "password"}))
    end

    test "a 403 without an error key is still a rejection" do
      assert {:error, {:rejected, 403, nil}} = respond_with(status: 403, body: ocs([]))
    end

    test "a redirect without a location is still reported" do
      assert {:error, {:redirected, nil}} = respond_with(status: 302, body: "")
    end

    test "a 400 with a body that is not JSON is a rejection without an error key" do
      assert {:error, {:rejected, 400, nil}} =
               respond_with(status: 400, body: "<html><body>Bad Request</body></html>")
    end

    test "a 429 is a rate limit, not a server error" do
      assert {:error, :rate_limited} = respond_with(status: 429, body: ocs(nil))
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
        respond_with(status: 401, body: ""),
        respond_with(status: 404, body: ocs(nil)),
        respond_with(status: 302, headers: %{"location" => ["https://cloud.example.com/login"]}),
        respond_with(status: 400, body: ocs(%{"error" => "password"})),
        respond_with(status: 429, body: ""),
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
end
