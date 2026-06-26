defmodule Tymeslot.MeetingTypes.AttachmentsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  @metadata %{
    "filename" => "agenda.pdf",
    "stored_path" => "attachments/1/2/123_agenda.pdf",
    "content_type" => "application/pdf",
    "byte_size" => 2048
  }

  describe "add_attachment/2" do
    test "appends an attachment with the given metadata" do
      meeting_type = insert(:meeting_type)

      assert {:ok, updated} = MeetingTypes.add_attachment(meeting_type, @metadata)

      assert [%{filename: "agenda.pdf", content_type: "application/pdf", byte_size: 2048}] =
               updated.attachments
    end

    test "keeps existing attachments when adding another" do
      {:ok, one} = MeetingTypes.add_attachment(insert(:meeting_type), @metadata)

      second = Map.put(@metadata, "filename", "brief.docx")
      assert {:ok, two} = MeetingTypes.add_attachment(one, second)

      assert ["agenda.pdf", "brief.docx"] = Enum.map(two.attachments, & &1.filename)
    end

    test "assigns each attachment a stable id" do
      {:ok, updated} = MeetingTypes.add_attachment(insert(:meeting_type), @metadata)

      assert [%{id: id}] = updated.attachments
      assert is_binary(id) and id != ""
    end
  end

  describe "remove_attachment/2" do
    test "removes the matching attachment and returns its stored path" do
      {:ok, with_one} = MeetingTypes.add_attachment(insert(:meeting_type), @metadata)
      [%{id: id, stored_path: stored_path}] = with_one.attachments

      assert {:ok, updated, ^stored_path} = MeetingTypes.remove_attachment(with_one, id)
      assert updated.attachments == []
    end

    test "leaves other attachments intact" do
      {:ok, one} = MeetingTypes.add_attachment(insert(:meeting_type), @metadata)
      {:ok, two} = MeetingTypes.add_attachment(one, Map.put(@metadata, "filename", "brief.docx"))
      [first, _second] = two.attachments

      assert {:ok, updated, _path} = MeetingTypes.remove_attachment(two, first.id)
      assert ["brief.docx"] = Enum.map(updated.attachments, & &1.filename)
    end
  end
end
