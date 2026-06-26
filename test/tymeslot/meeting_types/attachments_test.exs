defmodule Tymeslot.MeetingTypes.AttachmentsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

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

    test "rejects a #{MeetingTypeSchema.max_attachments() + 1}th attachment with a changeset error" do
      max = MeetingTypeSchema.max_attachments()
      meeting_type = insert(:meeting_type)

      # Fill up to the limit using distinct stored_paths to satisfy uniqueness.
      full_type =
        Enum.reduce(1..max, meeting_type, fn i, acc ->
          meta = Map.put(@metadata, "stored_path", "attachments/u/#{i}/file.pdf")
          {:ok, updated} = MeetingTypes.add_attachment(acc, meta)
          updated
        end)

      assert {:error, changeset} =
               MeetingTypes.add_attachment(
                 full_type,
                 Map.put(@metadata, "stored_path", "attachments/u/extra/file.pdf")
               )

      assert {message, _meta} = changeset.errors[:attachments]
      assert message == "cannot have more than #{max} attachments"
    end
  end

  describe "remove_attachment/2" do
    test "removes the matching attachment and returns its stored path when no booking references it" do
      {:ok, with_one} = MeetingTypes.add_attachment(insert(:meeting_type), @metadata)
      [%{id: id, stored_path: stored_path}] = with_one.attachments

      # No booking snapshot references this path — the domain returns the path
      # so the caller knows the file is safe to physically delete.
      assert {:ok, updated, ^stored_path} = MeetingTypes.remove_attachment(with_one, id)
      assert updated.attachments == []
    end

    test "returns nil as stored_path when a booking snapshot still references the file" do
      {:ok, with_one} = MeetingTypes.add_attachment(insert(:meeting_type), @metadata)
      [%{id: id, stored_path: stored_path}] = with_one.attachments

      # Simulate a confirmed booking whose snapshot captured this file.
      insert(:meeting,
        attachments_snapshot: [
          %{
            "id" => "snap-id",
            "filename" => "agenda.pdf",
            "stored_path" => stored_path,
            "content_type" => "application/pdf",
            "byte_size" => 2048
          }
        ]
      )

      # The domain must NOT return the path for physical deletion when a
      # booking still references the file.
      assert {:ok, updated, nil} = MeetingTypes.remove_attachment(with_one, id)
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
