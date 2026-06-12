defmodule Tymeslot.Slack.APITest do
  use ExUnit.Case, async: true

  @moduletag :slack
  @moduletag :unit

  import Mox

  alias Tymeslot.Slack.API

  setup :verify_on_exit!

  describe "post_message_via_token/3" do
    test "returns {:ok, body} on successful Slack response" do
      expect(Tymeslot.HTTPClientMock, :post, fn url, body, headers, _opts ->
        assert url == "https://slack.com/api/chat.postMessage"
        decoded = Jason.decode!(body)
        assert decoded["channel"] == "C42"
        assert decoded["blocks"] == [%{"type" => "section", "text" => %{"text" => "hello"}}]
        assert decoded["text"] == "hello"
        assert decoded["unfurl_links"] == false
        assert decoded["unfurl_media"] == false

        assert {"authorization", "Bearer xoxb-real"} in headers
        assert {"content-type", "application/json; charset=utf-8"} in headers

        {:ok, %{status: 200, body: ~s({"ok":true,"ts":"123.456","channel":"C42"})}}
      end)

      blocks = [%{"type" => "section", "text" => %{"text" => "hello"}}]

      assert {:ok, %{"ok" => true, "ts" => "123.456"}} =
               API.post_message_via_token("xoxb-real", "C42", blocks)
    end

    test "translates Slack ok:false body into a slack_error tuple" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"ok":false,"error":"channel_not_found"})}}
      end)

      assert {:error, {:slack_error, "channel_not_found", %{"ok" => false}}} =
               API.post_message_via_token("xoxb", "C0", [
                 %{"type" => "section", "text" => %{"text" => "hi"}}
               ])
    end

    test "returns http_error for non-200 status" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 503, body: "service unavailable"}}
      end)

      assert {:error, {:http_error, 503, "service unavailable"}} =
               API.post_message_via_token("xoxb", "C0", [])
    end

    test "returns transport_error on connection failure" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      assert {:error, {:transport_error, %Mint.TransportError{reason: :timeout}}} =
               API.post_message_via_token("xoxb", "C0", [])
    end

    test "maps a real HTTP 429 with Retry-After to a rate_limited tuple" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 429, body: "", headers: %{"retry-after" => ["17"]}}}
      end)

      assert {:error, {:rate_limited, 17}} =
               API.post_message_via_token("xoxb", "C0", [
                 %{"type" => "section", "text" => %{"text" => "hi"}}
               ])
    end

    test "maps a 429 without Retry-After to a rate_limited tuple with nil interval" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 429, body: ""}}
      end)

      assert {:error, {:rate_limited, nil}} = API.post_message_via_token("xoxb", "C0", [])
    end

    test "uses the first header/section block text as the fallback text" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["text"] == "New booking"
        {:ok, %{status: 200, body: ~s({"ok":true})}}
      end)

      blocks = [
        %{"type" => "header", "text" => %{"text" => "New booking"}},
        %{"type" => "section", "text" => %{"text" => "Body details"}}
      ]

      assert {:ok, _body} = API.post_message_via_token("xoxb", "C42", blocks)
    end
  end

  describe "post_message_via_webhook/2" do
    test "returns {:ok, %{}} on 200" do
      expect(Tymeslot.HTTPClientMock, :post, fn url, body, headers, _opts ->
        assert url == "https://hooks.slack.com/services/T/B/abc"
        assert {"content-type", "application/json; charset=utf-8"} in headers
        decoded = Jason.decode!(body)
        assert decoded["blocks"] == []
        {:ok, %{status: 200, body: "ok"}}
      end)

      assert {:ok, %{}} =
               API.post_message_via_webhook("https://hooks.slack.com/services/T/B/abc", [])
    end

    test "returns webhook_error on 4xx with body text" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 404, body: "no_service"}}
      end)

      assert {:error, {:webhook_error, 404, "no_service"}} =
               API.post_message_via_webhook("https://hooks.slack.com/services/T/B/abc", [])
    end

    test "returns transport_error on connection failure" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :nxdomain}}
      end)

      assert {:error, {:transport_error, _reason}} =
               API.post_message_via_webhook("https://hooks.slack.com/services/T/B/abc", [])
    end

    test "maps a webhook HTTP 429 with Retry-After to a rate_limited tuple" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 429, body: "rate_limited", headers: %{"retry-after" => ["8"]}}}
      end)

      assert {:error, {:rate_limited, 8}} =
               API.post_message_via_webhook("https://hooks.slack.com/services/T/B/abc", [])
    end
  end

  describe "list_conversations/2" do
    test "passes cursor and types in the query string" do
      expect(Tymeslot.HTTPClientMock, :get, fn url, headers, _opts ->
        uri = URI.parse(url)
        assert uri.host == "slack.com"
        assert uri.path == "/api/conversations.list"
        params = URI.decode_query(uri.query)
        assert params["types"] == "public_channel,private_channel"
        assert params["limit"] == "200"
        assert params["exclude_archived"] == "true"
        assert params["cursor"] == "page2"
        assert {"authorization", "Bearer xoxb-bot"} in headers

        {:ok,
         %{
           status: 200,
           body:
             ~s({"ok":true,"channels":[{"id":"C1","name":"general","is_private":false}],"response_metadata":{"next_cursor":""}})
         }}
      end)

      assert {:ok, %{"ok" => true, "channels" => [_chan]}} =
               API.list_conversations("xoxb-bot", cursor: "page2")
    end

    test "omits cursor when not provided" do
      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
        refute Map.has_key?(params, "cursor")
        {:ok, %{status: 200, body: ~s({"ok":true,"channels":[]})}}
      end)

      assert {:ok, _body} = API.list_conversations("xoxb")
    end
  end

  describe "oauth_v2_access/4" do
    test "POSTs form-encoded credentials and returns the body" do
      expect(Tymeslot.HTTPClientMock, :post, fn url, body, headers, _opts ->
        assert url == "https://slack.com/api/oauth.v2.access"
        assert {"content-type", "application/x-www-form-urlencoded"} in headers
        params = URI.decode_query(body)
        assert params["client_id"] == "id1"
        assert params["client_secret"] == "secret1"
        assert params["code"] == "code1"
        assert params["redirect_uri"] == "https://example/cb"

        {:ok,
         %{
           status: 200,
           body:
             ~s({"ok":true,"access_token":"xoxb-real","team":{"id":"T1","name":"Acme"},"authed_user":{"id":"U7"},"scope":"chat:write"})
         }}
      end)

      assert {:ok, %{"access_token" => "xoxb-real"}} =
               API.oauth_v2_access("id1", "secret1", "code1", "https://example/cb")
    end
  end

  describe "auth_test/1" do
    test "returns the verified workspace metadata on success" do
      expect(Tymeslot.HTTPClientMock, :post, fn url, _body, headers, _opts ->
        assert url == "https://slack.com/api/auth.test"
        assert {"authorization", "Bearer xoxb"} in headers
        {:ok, %{status: 200, body: ~s({"ok":true,"team":"Acme","user":"bot"})}}
      end)

      assert {:ok, %{"team" => "Acme"}} = API.auth_test("xoxb")
    end
  end
end
