defmodule Tymeslot.MeetingTypes.Attachments do
  @moduledoc """
  Domain logic for host-uploaded meeting-type attachments.

  Persists attachment metadata on the meeting type (the file bytes are stored by
  the web layer) and decides, on removal, whether a file is safe to physically
  delete — it must be kept while any past booking's snapshot still references it.
  """

  alias Tymeslot.Meetings.AttachmentSnapshotQueries
  alias Tymeslot.MeetingTypes.MeetingTypeQueries

  @doc """
  Appends a host-uploaded attachment to a meeting type. `metadata` carries the
  stored-file fields (`filename`, `stored_path`, `content_type`, `byte_size`).
  The file itself must already be persisted by the caller (web layer).
  """
  @spec add_attachment(Ecto.Schema.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def add_attachment(meeting_type, metadata) when is_map(metadata) do
    attrs = %{attachments: existing_attachment_params(meeting_type) ++ [metadata]}
    MeetingTypeQueries.update_attachments(meeting_type, attrs)
  end

  @doc """
  Removes the attachment with the given id from a meeting type.

  Returns `{:ok, updated_type, path_to_delete}` where `path_to_delete` is the
  `stored_path` only when no past booking's `attachments_snapshot` still
  references it (so the caller may safely unlink the file), or `nil` when the
  file must be kept so existing booking links continue to resolve.
  """
  @spec remove_attachment(Ecto.Schema.t(), String.t()) ::
          {:ok, Ecto.Schema.t(), String.t() | nil} | {:error, Ecto.Changeset.t()}
  def remove_attachment(meeting_type, attachment_id) do
    {removed, kept} =
      Enum.split_with(meeting_type.attachments || [], &(&1.id == attachment_id))

    attrs = %{attachments: Enum.map(kept, &attachment_params/1)}

    case MeetingTypeQueries.update_attachments(meeting_type, attrs) do
      {:ok, updated} ->
        stored_path = removed |> List.first() |> then(&(&1 && &1.stored_path))

        deletable =
          is_binary(stored_path) and
            not AttachmentSnapshotQueries.attachment_path_referenced?(stored_path)

        {:ok, updated, if(deletable, do: stored_path, else: nil)}

      error ->
        error
    end
  end

  defp existing_attachment_params(meeting_type) do
    Enum.map(meeting_type.attachments || [], &attachment_params/1)
  end

  defp attachment_params(attachment) do
    %{
      "id" => attachment.id,
      "filename" => attachment.filename,
      "stored_path" => attachment.stored_path,
      "content_type" => attachment.content_type,
      "byte_size" => attachment.byte_size
    }
  end
end
