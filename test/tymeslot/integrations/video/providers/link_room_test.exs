defmodule Tymeslot.Integrations.Video.Providers.LinkRoomTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Video.Providers.LinkRoom
  alias Tymeslot.Integrations.Video.TemplateConfig

  # An IP literal in TEST-NET-3, as in the custom provider's reachability
  # suite: nothing here reaches the network, since the HTTP client is a mock.
  @public_url "https://203.0.113.10/room"

  setup :verify_on_exit!

  describe "slug/1" do
    test "returns a lowercase hex slug of the configured hash length" do
      assert {:ok, slug} = LinkRoom.slug("meeting-42")
      assert String.length(slug) == TemplateConfig.hash_length()
      assert slug =~ ~r/\A[0-9a-f]+\z/
    end

    test "is the truncated SHA256 of the meeting id" do
      # Computed from the original custom provider algorithm, not from LinkRoom:
      # :crypto.hash(:sha256, "meeting-42") |> Base.encode16(case: :lower)
      # |> String.slice(0, 16). A change here breaks every existing room URL.
      assert LinkRoom.slug("meeting-42") == {:ok, "af9e058f6f69d39b"}
    end

    test "is deterministic for the same meeting id" do
      assert LinkRoom.slug("meeting-42") == LinkRoom.slug("meeting-42")
    end

    test "differs for different meeting ids" do
      assert LinkRoom.slug("meeting-42") != LinkRoom.slug("meeting-43")
    end

    test "accepts integer meeting ids" do
      assert {:ok, slug} = LinkRoom.slug(42)
      assert {:ok, ^slug} = LinkRoom.slug("42")
    end

    test "refuses a nil or empty meeting id" do
      assert {:error, _message} = LinkRoom.slug(nil)
      assert {:error, _message} = LinkRoom.slug("")
    end
  end

  describe "append_slug/2" do
    test "joins base URL and slug with a single separator" do
      assert LinkRoom.append_slug("https://meet.example.com", "abc123") ==
               "https://meet.example.com/abc123"
    end

    test "does not double the separator when the base URL has a trailing slash" do
      assert LinkRoom.append_slug("https://meet.example.com/", "abc123") ==
               "https://meet.example.com/abc123"
    end

    test "preserves a path prefix on the base URL" do
      assert LinkRoom.append_slug("https://example.com/jitsi", "abc123") ==
               "https://example.com/jitsi/abc123"
    end
  end

  describe "http_url?/1" do
    test "accepts http and https URLs with a host" do
      assert LinkRoom.http_url?("https://meet.example.com/room")
      assert LinkRoom.http_url?("http://meet.example.com/room")
    end

    test "rejects other schemes, hostless URLs and non-binaries" do
      refute LinkRoom.http_url?("ftp://meet.example.com/room")
      refute LinkRoom.http_url?("https:///room")
      refute LinkRoom.http_url?(nil)
    end
  end

  describe "validate_length/1" do
    test "accepts a URL at the limit" do
      prefix = "https://e.com/"

      url =
        prefix <> String.duplicate("a", TemplateConfig.max_url_length() - String.length(prefix))

      assert String.length(url) == TemplateConfig.max_url_length()
      assert :ok = LinkRoom.validate_length(url)
    end

    test "rejects a URL past the limit" do
      url = "https://e.com/" <> String.duplicate("a", TemplateConfig.max_url_length())
      assert {:error, _message} = LinkRoom.validate_length(url)
    end
  end

  describe "room_id/1" do
    test "is deterministic and 16 characters" do
      id = LinkRoom.room_id("https://meet.example.com/abc")
      assert String.length(id) == 16
      assert id == LinkRoom.room_id("https://meet.example.com/abc")
    end

    test "is the truncated MD5 of the URL" do
      # Computed from the original custom provider algorithm, not from LinkRoom:
      # :crypto.hash(:md5, url) |> Base.encode16(case: :lower) |> String.slice(0, 16).
      assert LinkRoom.room_id("https://meet.example.com/abc") == "5268597d475c20a1"
    end
  end

  describe "probe/1" do
    test "refuses a non-http scheme before making any request" do
      expect(Tymeslot.HTTPClientMock, :head, 0, fn _url, _headers, _opts -> :unreachable end)
      expect(Tymeslot.HTTPClientMock, :get, 0, fn _url, _headers, _opts -> :unreachable end)

      assert LinkRoom.probe("ftp://203.0.113.10/room") ==
               {:error, "Invalid URL scheme. Only http and https are supported"}
    end

    test "reports a 2xx status as reachable" do
      expect(Tymeslot.HTTPClientMock, :head, fn @public_url, _headers, _opts ->
        {:ok, %Req.Response{status: 204, headers: %{}}}
      end)

      assert LinkRoom.probe(@public_url) == {:ok, 204}
    end

    test "falls back to GET when HEAD is not allowed" do
      expect(Tymeslot.HTTPClientMock, :head, fn @public_url, _headers, _opts ->
        {:ok, %Req.Response{status: 405, headers: %{}}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn @public_url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, headers: %{}}}
      end)

      assert LinkRoom.probe(@public_url) == {:ok, 200}
    end

    test "reports a transport timeout as a timeout" do
      expect(Tymeslot.HTTPClientMock, :head, fn _url, _headers, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert LinkRoom.probe(@public_url) ==
               {:error, "Connection timeout while reaching the URL"}
    end

    test "reports a non-2xx status with the status code" do
      expect(Tymeslot.HTTPClientMock, :head, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 503, headers: %{}}}
      end)

      assert LinkRoom.probe(@public_url) == {:error, "URL responded with HTTP 503"}
    end
  end
end
