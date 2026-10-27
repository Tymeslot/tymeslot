defmodule Tymeslot.Emails.Shared.Meeting.NotesTest do
  # Not async: asserts the absence of a log event, and the capture handler is
  # global.
  use Tymeslot.DataCase, async: false
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Meeting.Notes
  alias Tymeslot.Test.LogCapture

  describe "organizer_note_box/2" do
    test "keeps the text after a double dash" do
      html = Notes.organizer_note_box(:confirmed, "Bring the laptop -- and the charger")

      assert html =~ "Bring the laptop -- and the charger"
    end

    test "escapes an unclosed tag fragment and markup" do
      html =
        Notes.organizer_note_box(
          :confirmed,
          ~s(Tom & Jerry <b>bold</b> <a href=https://x.example style=color:red)
        )

      assert html =~ "Tom &amp; Jerry"
      assert html =~ "&lt;b&gt;bold&lt;/b&gt;"
      assert html =~ "&lt;a href=https://x.example style=color:red"
      refute html =~ "<a href=https://x.example"
      refute html =~ "<b>"
    end

    test "escapes a script tag" do
      html = Notes.organizer_note_box(:confirmed, "<script>alert(1)</script>")

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>"
    end

    test "turns newlines into line breaks" do
      html = Notes.organizer_note_box(:confirmed, "First line\nSecond line")

      assert html =~ "First line<br>Second line"
    end

    test "renders nothing for a missing or empty note" do
      assert Notes.organizer_note_box(:confirmed, nil) == ""
      assert Notes.organizer_note_box(:confirmed, "") == ""
    end

    test "logs no security event when rendering a note" do
      LogCapture.attach()

      html = Notes.organizer_note_box(:confirmed, "Path ../docs -- see 0x1F")

      assert html =~ "Path ../docs -- see 0x1F"

      assert Enum.filter(LogCapture.drain(), fn %{msg: msg} ->
               LogCapture.message_text(msg) =~ "Suspicious input"
             end) == []
    end
  end
end
