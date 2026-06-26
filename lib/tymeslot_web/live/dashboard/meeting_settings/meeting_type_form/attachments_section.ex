defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.AttachmentsSection do
  @moduledoc """
  Stateless function component for the meeting-type form's Attachments section.

  Lets the host attach files (agenda, brief, documents) that are surfaced on
  every booking of this type — in the calendar event (`ATTACH` + a links block)
  and the confirmation email. Uploads and removals dispatch back to the parent
  `MeetingTypeForm` (`@myself`), which owns the socket, the upload config and
  persistence. Attachments require a saved meeting type, so the section is only
  rendered in edit mode.
  """

  use TymeslotWeb, :html

  alias TymeslotWeb.Helpers.UploadConstraints

  attr :attachments, :list, required: true
  attr :upload, :any, required: true
  attr :myself, :any, required: true

  @spec attachments_section(map()) :: Phoenix.LiveView.Rendered.t()
  def attachments_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center gap-2">
        <.icon name="hero-paper-clip" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-800">Attachments</h3>
      </div>

      <p class="text-token-sm text-tymeslot-500">
        Files you add here are shared on every booking of this meeting type, in the
        calendar invitation and the confirmation email. Up to {format_size()} each.
      </p>

      <ul :if={@attachments != []} class="space-y-2">
        <li
          :for={attachment <- @attachments}
          class="card-glass flex items-center justify-between gap-3 p-3"
        >
          <span class="flex min-w-0 items-center gap-2">
            <.icon name="hero-document" class="w-4 h-4 shrink-0 text-tymeslot-400" />
            <span class="truncate text-token-sm text-tymeslot-700">{attachment.filename}</span>
          </span>
          <button
            type="button"
            class="text-token-sm text-red-500 hover:text-red-600"
            phx-click="remove_attachment"
            phx-value-id={attachment.id}
            phx-target={@myself}
          >
            Remove
          </button>
        </li>
      </ul>

      <form
        id="attachment-upload-form"
        phx-change="validate_attachment"
        phx-submit="upload_attachment"
        phx-target={@myself}
      >
        <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
          <.live_file_input upload={@upload} class="text-token-sm" />
          <button type="submit" class="btn btn-secondary" disabled={@upload.entries == []}>
            Upload
          </button>
        </div>

        <p :for={err <- upload_errors(@upload)} class="form-error mt-2">
          {error_to_string(err)}
        </p>
        <%= for entry <- @upload.entries do %>
          <p :for={err <- upload_errors(@upload, entry)} class="form-error mt-2">
            {error_to_string(err)}
          </p>
        <% end %>
      </form>
    </section>
    """
  end

  defp format_size do
    mb = div(UploadConstraints.max_file_size(:attachment), 1_000_000)
    "#{mb}MB"
  end

  defp error_to_string(:too_large), do: "File is too large."
  defp error_to_string(:too_many_files), do: "You can only upload one file at a time."
  defp error_to_string(:not_accepted), do: "That file type isn't allowed."
  defp error_to_string(_other), do: "Upload failed. Please try again."
end
