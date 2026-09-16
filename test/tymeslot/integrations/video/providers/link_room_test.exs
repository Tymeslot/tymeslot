defmodule Tymeslot.Integrations.Video.Providers.LinkRoomTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Providers.LinkRoom
  alias Tymeslot.Integrations.Video.TemplateConfig

  describe "slug/1" do
    test "returns a 16-character lowercase hex slug" do
      assert {:ok, slug} = LinkRoom.slug("meeting-42")
      assert String.length(slug) == TemplateConfig.hash_length()
      assert slug =~ ~r/\A[0-9a-f]+\z/
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
      url = "https://e.com/" <> String.duplicate("a", TemplateConfig.max_url_length() - 14)
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
  end
end
