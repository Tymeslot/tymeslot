defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Attachments do
  @moduledoc """
  Attachment upload/removal logic for the meeting-type form, kept out of the
  `MeetingTypeForm` LiveComponent itself. The component's `handle_event`
  clauses delegate here; this module owns the file storage (web layer) and the
  metadata persistence (domain) and returns the updated socket.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [consume_uploaded_entries: 3]

  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Helpers.AttachmentUpload

  @doc "Consumes pending uploads, stores them, and persists their metadata."
  @spec upload(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def upload(socket) do
    user_id = socket.assigns.current_user.id

    results =
      consume_uploaded_entries(socket, :attachment, fn %{path: path}, entry ->
        {:ok,
         AttachmentUpload.store(user_id, socket.assigns.type.id, %{
           path: path,
           client_name: entry.client_name
         })}
      end)

    meeting_type = Enum.reduce(results, socket.assigns.type, &apply_stored/2)

    assign(socket, :type, meeting_type)
  end

  @doc "Removes an attachment by id and deletes its stored file."
  @spec remove(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def remove(socket, attachment_id) do
    case MeetingTypes.remove_attachment(socket.assigns.type, attachment_id) do
      {:ok, updated, stored_path} ->
        AttachmentUpload.delete(stored_path)
        assign(socket, :type, updated)

      {:error, _changeset} ->
        socket
    end
  end

  defp apply_stored({:ok, metadata}, type) do
    case MeetingTypes.add_attachment(type, metadata) do
      {:ok, updated} -> updated
      {:error, _changeset} -> type
    end
  end

  defp apply_stored({:error, _reason}, type), do: type
end
