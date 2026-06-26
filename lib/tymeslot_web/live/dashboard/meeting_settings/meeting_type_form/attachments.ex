defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Attachments do
  @moduledoc """
  Attachment upload/removal logic for the meeting-type form, kept out of the
  `MeetingTypeForm` LiveComponent itself. The component's `handle_event`
  clauses delegate here; this module owns the file storage (web layer) and the
  metadata persistence (domain) and returns the updated socket.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [consume_uploaded_entries: 3]

  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Helpers.AttachmentUpload
  alias TymeslotWeb.Live.Shared.Flash

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

  @doc """
  Removes an attachment by id.

  `MeetingTypes.remove_attachment/2` decides whether the physical file is safe
  to delete: it returns a non-nil `stored_path` only when no past booking's
  `attachments_snapshot` still references the file. When the path is `nil` the
  file is kept alive so existing booking links continue to resolve.
  """
  @spec remove(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def remove(socket, attachment_id) do
    case MeetingTypes.remove_attachment(socket.assigns.type, attachment_id) do
      {:ok, updated, stored_path} ->
        # stored_path is nil when the file is still referenced by a booking
        # snapshot — AttachmentUpload.delete/1 is a no-op for nil.
        AttachmentUpload.delete(stored_path)
        assign(socket, :type, updated)

      {:error, changeset} ->
        Logger.error("Failed to remove attachment",
          attachment_id: attachment_id,
          errors: inspect(changeset.errors)
        )

        Flash.error("Could not remove attachment. Please try again.")
        socket
    end
  end

  defp apply_stored({:ok, metadata}, type) do
    case MeetingTypes.add_attachment(type, metadata) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.error("Failed to persist attachment metadata",
          errors: inspect(changeset.errors)
        )

        Flash.error("Could not save attachment. Please try again.")
        type
    end
  end

  defp apply_stored({:error, reason}, type) do
    Logger.error("Failed to store attachment file", reason: inspect(reason))
    Flash.error("Could not upload attachment. Please try again.")
    type
  end
end
