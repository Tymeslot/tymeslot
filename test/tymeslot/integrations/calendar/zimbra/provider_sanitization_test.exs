defmodule Tymeslot.Integrations.Calendar.Zimbra.ProviderSanitizationTest do
  @moduledoc """
  Security-focused tests for Zimbra provider input sanitization.
  Tests path traversal, null bytes, control characters, and other injection attempts.
  """
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Zimbra.Provider

  describe "new/1 - calendar name sanitization" do
    test "sanitizes calendar names with path traversal attempts" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["../../../etc/passwd"]
      }

      client = Provider.new(config)

      # Should produce exactly one sanitized path without path traversal
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      assert String.contains?(path, "/dav/user@example.com/")
      assert String.ends_with?(path, "/")
      refute String.contains?(path, "..")
    end

    test "handles calendar names with null bytes" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["Calendar\x00Name"]
      }

      client = Provider.new(config)

      # Should produce path with null bytes removed
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      assert String.contains?(path, "CalendarName")
      refute String.contains?(path, "\x00")
    end

    test "handles very long calendar names" do
      long_name = String.duplicate("a", 1000)

      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: [long_name]
      }

      client = Provider.new(config)

      # Sanitization truncates the name to 200 characters, so the path fits
      # inside the 255-byte cap and survives. Assert the exact result: an empty
      # list here would mean truncation stopped happening.
      assert client.calendar_paths == ["/dav/user@example.com/#{String.duplicate("a", 200)}/"]
      assert [path] = client.calendar_paths
      assert byte_size(path) == 223
    end

    test "rejects a multi-byte calendar name whose path exceeds the byte limit" do
      # 60 emoji is 60 characters, so the 200-character truncation in
      # sanitize_calendar_name/1 does not shorten it, but it is 240 bytes and the
      # resulting path is 263 bytes. The byte check rejects it outright rather
      # than truncating, so the name is dropped and no path is produced.
      emoji_name = String.duplicate("📅", 60)

      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: [emoji_name]
      }

      assert byte_size("/dav/user@example.com/#{emoji_name}/") == 263

      client = Provider.new(config)

      assert client.calendar_paths == []
    end

    test "handles empty calendar names" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["", "  ", "ValidName"]
      }

      client = Provider.new(config)

      # Empty and whitespace-only names are dropped; only ValidName survives.
      assert client.calendar_paths == ["/dav/user@example.com/ValidName/"]
    end

    test "sanitizes pre-formatted paths with path traversal (security fix)" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["/dav/user@example.com/../../../etc/passwd"]
      }

      client = Provider.new(config)

      # Critical: Pre-formatted paths must be sanitized to prevent path traversal.
      # Assert the path count first: an empty list would otherwise skip the check.
      assert length(client.calendar_paths) == 1

      assert Enum.all?(client.calendar_paths, fn path ->
               not String.contains?(path, "..")
             end)
    end

    test "sanitizes pre-formatted paths with complex traversal patterns" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: [
          "/dav/user@example.com/Calendar/../../sensitive",
          "/dav/user@example.com/....//etc/passwd",
          "/dav/user@example.com/..",
          "/dav/user@example.com/..."
        ]
      }

      client = Provider.new(config)

      # All path traversal sequences should be removed
      assert Enum.all?(client.calendar_paths, fn path ->
               not String.contains?(path, "..")
             end)
    end

    test "handles Unicode in calendar names" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["📅 Calendar", "日本語カレンダー", "Календарь", "Arbeit✓"]
      }

      client = Provider.new(config)

      # Unicode names are preserved verbatim, not stripped or transliterated.
      assert client.calendar_paths == [
               "/dav/user@example.com/📅 Calendar/",
               "/dav/user@example.com/日本語カレンダー/",
               "/dav/user@example.com/Календарь/",
               "/dav/user@example.com/Arbeit✓/"
             ]
    end

    test "handles mixed Unicode and ASCII in calendar names" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com",
        password: "pass",
        calendar_names: ["Work🏢", "Home🏠", "Calendar-2024"]
      }

      client = Provider.new(config)

      assert client.calendar_paths == [
               "/dav/user@example.com/Work🏢/",
               "/dav/user@example.com/Home🏠/",
               "/dav/user@example.com/Calendar-2024/"
             ]

      assert Enum.all?(client.calendar_paths, &String.valid?/1)
    end
  end

  describe "new/1 - username sanitization (CRITICAL SECURITY)" do
    test "sanitizes username with path traversal attempts" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com/../../etc",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should produce path without path traversal in username component
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "..")
      # Verify path structure is maintained
      assert String.starts_with?(path, "/dav/")
      assert String.ends_with?(path, "/")
    end

    test "sanitizes username with null bytes" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user\x00@example.com",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should produce path with null bytes removed from username
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "\x00")
      assert String.contains?(path, "user@example.com")
    end

    test "sanitizes username with control characters" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user\r\n@example.com",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should remove control characters from username
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "\r")
      refute String.contains?(path, "\n")
    end

    test "handles very long username (DoS protection)" do
      long_username = String.duplicate("a", 1000) <> "@example.com"

      config = %{
        base_url: "https://mail.example.com",
        username: long_username,
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # The username is truncated to 200 characters, keeping the path inside the
      # 255-byte cap. Assert the exact path: an empty list would mean the
      # truncation stopped happening and the whole path was rejected instead.
      assert client.calendar_paths == ["/dav/#{String.duplicate("a", 200)}/Calendar/"]
      assert [path] = client.calendar_paths
      assert byte_size(path) == 215
    end

    test "sanitizes username with complex path traversal patterns" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user@example.com/../../../etc/passwd",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should remove all path traversal sequences (..)
      # The text "etc/passwd" may remain as it's just text after .. is removed
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "..")
    end

    test "rejects empty username after sanitization" do
      config = %{
        base_url: "https://mail.example.com",
        username: "../../",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should produce no paths when username becomes empty after sanitization
      assert client.calendar_paths == []
    end

    test "handles username and calendar name both with path traversal" do
      config = %{
        base_url: "https://mail.example.com",
        username: "user/../admin",
        password: "pass",
        calendar_names: ["../../etc/passwd"]
      }

      client = Provider.new(config)

      # Both username and calendar name should be sanitized
      assert length(client.calendar_paths) == 1
      path = hd(client.calendar_paths)
      refute String.contains?(path, "..")
    end
  end

  describe "new/1 - edge cases and special handling" do
    test "handles nil username gracefully" do
      config = %{
        base_url: "https://mail.example.com",
        username: nil,
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should return empty calendar_paths when username is nil
      assert client.calendar_paths == []
    end

    test "handles empty username gracefully" do
      config = %{
        base_url: "https://mail.example.com",
        username: "",
        password: "pass",
        calendar_names: ["Calendar"]
      }

      client = Provider.new(config)

      # Should return empty calendar_paths when username is empty
      assert client.calendar_paths == []
    end
  end
end
