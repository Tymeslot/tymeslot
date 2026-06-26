defmodule Tymeslot.Integrations.Calendar.ICalBuilderAttachmentTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalBuilder

  # RFC 5545 §3.1 — content lines must not exceed 75 octets. The newly-added
  # ATTACH and CONFERENCE properties carry production URLs that routinely
  # exceed that limit, so build_simple_event/2 now folds its output.

  describe "build_simple_event/2 — RFC 5545 §3.1 line folding" do
    test "no output line exceeds 75 octets when ATTACH URL is long" do
      # ATTACH;FMTTYPE=application/pdf: = 32 octets; total will exceed 75
      long_url =
        "https://app.tymeslot.com/uploads/meetings/some-unique-meeting-identifier/important-document-2024.pdf"

      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        attachments: [%{url: long_url, content_type: "application/pdf"}]
      }

      ical = ICalBuilder.build_simple_event("uid-fold-attach", event_data)

      ical
      |> String.split("\r\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.each(fn line ->
        assert byte_size(line) <= 75, "Line exceeds 75 octets: #{inspect(line)}"
      end)

      unfolded = String.replace(ical, "\r\n ", "")
      assert String.contains?(unfolded, "ATTACH;FMTTYPE=application/pdf:#{long_url}")
    end

    test "unfolding reconstructs the original CONFERENCE URL intact" do
      # CONFERENCE;VALUE=URI;FEATURE=VIDEO: = 35 octets; total will exceed 75
      long_url = "https://meet.example.com/room/abc-def-ghi-jkl-mno-pqr-stu-vwx/join?authuser=0"

      event_data = %{
        summary: "Video Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        conference_url: long_url
      }

      ical = ICalBuilder.build_simple_event("uid-fold-conf", event_data)

      ical
      |> String.split("\r\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.each(fn line ->
        assert byte_size(line) <= 75, "Line exceeds 75 octets: #{inspect(line)}"
      end)

      unfolded = String.replace(ical, "\r\n ", "")
      assert String.contains?(unfolded, "CONFERENCE;VALUE=URI;FEATURE=VIDEO:#{long_url}")
    end

    test "short lines are not folded" do
      event_data = %{
        summary: "Short",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event("uid-short", event_data)

      refute String.contains?(ical, "\r\n ")
    end
  end

  # RFC 5545 §3.8.1.1 — one ATTACH line per file, FMTTYPE carries the MIME
  # type when known.

  describe "build_simple_event/2 — ATTACH lines" do
    test "emits ATTACH;FMTTYPE line when content_type is present" do
      event_data = %{
        summary: "Meeting with Attachment",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        attachments: [%{url: "https://example.com/file.pdf", content_type: "application/pdf"}]
      }

      ical =
        "uid-attach-fmttype"
        |> ICalBuilder.build_simple_event(event_data)
        |> String.replace("\r\n ", "")

      assert String.contains?(
               ical,
               "ATTACH;FMTTYPE=application/pdf:https://example.com/file.pdf"
             )
    end

    test "emits bare ATTACH line when content_type is absent" do
      event_data = %{
        summary: "Meeting with Attachment",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        attachments: [%{url: "https://example.com/file.pdf"}]
      }

      ical = ICalBuilder.build_simple_event("uid-attach-bare", event_data)

      assert String.contains?(ical, "ATTACH:https://example.com/file.pdf")
      refute String.contains?(ical, "FMTTYPE")
    end

    test "emits one ATTACH line per attachment, FMTTYPE only when content_type is set" do
      event_data = %{
        summary: "Meeting with Attachments",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        attachments: [
          %{url: "https://example.com/file1.pdf", content_type: "application/pdf"},
          %{url: "https://example.com/file2.png"}
        ]
      }

      ical =
        "uid-attach-multi"
        |> ICalBuilder.build_simple_event(event_data)
        |> String.replace("\r\n ", "")

      assert String.contains?(
               ical,
               "ATTACH;FMTTYPE=application/pdf:https://example.com/file1.pdf"
             )

      assert String.contains?(ical, "ATTACH:https://example.com/file2.png")
    end

    test "omits ATTACH entirely when attachments list is empty" do
      event_data = %{
        summary: "Meeting without Attachments",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        attachments: []
      }

      ical = ICalBuilder.build_simple_event("uid-attach-empty", event_data)

      refute String.contains?(ical, "ATTACH")
    end

    test "sanitizes control characters from attachment URLs" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        attachments: [%{url: "https://example.com/\r\nfile.pdf"}]
      }

      ical = ICalBuilder.build_simple_event("uid-attach-sanitize", event_data)

      refute String.contains?(ical, "https://example.com/\r\nfile.pdf")
      assert String.contains?(ical, "ATTACH:https://example.com/file.pdf")
    end
  end
end
