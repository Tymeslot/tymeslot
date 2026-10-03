defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Creation do
  @moduledoc """
  The one explicit save in the meeting-type editor: creating the record.

  Auto-save needs a record to save into, so while a meeting type is new the
  editor shows only its Details tab and a "Create meeting type" button. That
  button lands here. On success the form switches in place to edit mode on
  the same component, so the organiser carries straight on to the other tabs
  with auto-save in charge; the parent `ServiceSettingsComponent` is told
  through `send_update/2` so it treats the new record as the one being
  edited. On failure the errors stay on the Details tab as inline field
  errors, or as a flash for failures that belong to no field.

  The record is built from the same socket state auto-save serialises
  (`Submission.build_params/1`), so the settings the other tabs default to
  for a new meeting type (one in-person location, the default reminder, the
  default schedule) are exactly what gets stored.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.FormHelpers
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Submission
  alias TymeslotWeb.Live.Shared.Flash

  # The Details fields the create submit posts. Each input already reports its
  # value through a debounced phx-change, but a click on "Create" can arrive
  # before the last of those, so the posted values win.
  @detail_fields ~w(name duration slot_interval description)

  @doc """
  Creates the meeting type from the form's current state, merged with the
  Details values posted by the submit.
  """
  @spec run(LiveView.Socket.t(), map()) :: LiveView.Socket.t()
  def run(socket, posted_params) do
    user = socket.assigns.current_user

    case RateLimiter.check_meeting_type_write_rate_limit(user.id) do
      :ok ->
        socket = merge_posted_details(socket, posted_params)

        socket.assigns
        |> Submission.build_params()
        |> Submission.persist(Helpers.get_security_metadata(socket), nil, user)
        |> apply_result(socket)

      {:error, :rate_limited, message} ->
        Flash.error(message)
        socket
    end
  end

  defp merge_posted_details(socket, posted_params) do
    posted = Map.take(posted_params, @detail_fields)
    Component.assign(socket, :form_data, Map.merge(socket.assigns.form_data, posted))
  end

  @doc """
  Applies the outcome of a create to the form: on success the form switches
  to edit mode on the new record and the parent is told; on failure the
  errors land on the form, with a flash for those that name no field.
  """
  @spec apply_result(
          {:ok, Ecto.Schema.t()} | {:error, {:invalid_form, map()} | Ecto.Changeset.t() | term()},
          LiveView.Socket.t()
        ) :: LiveView.Socket.t()
  def apply_result({:ok, meeting_type}, socket) do
    LiveView.send_update(socket.assigns.parent_myself, meeting_type_created: meeting_type)
    Flash.info(dgettext("dashboard_meeting_form", "Meeting type created"))

    Component.assign(socket,
      type: meeting_type,
      is_edit: true,
      form_errors: %{},
      save_status: :saved
    )
  end

  def apply_result({:error, {:invalid_form, errors}}, socket) do
    Component.assign(socket, :form_errors, errors)
  end

  def apply_result({:error, %Ecto.Changeset{} = changeset}, socket) do
    Component.assign(socket, :form_errors, FormHelpers.format_changeset_errors(changeset))
  end

  # Gated features refuse the whole save without naming a field.
  def apply_result({:error, reason}, socket)
      when reason in [:insufficient_plan, :feature_access_checker_failed] do
    Flash.error(error_message(reason))
    socket
  end

  def apply_result({:error, reason}, socket) do
    Flash.error(error_message(reason))
    Component.assign(socket, :form_errors, FormHelpers.format_context_error(reason))
  end

  defp error_message(:video_integration_required),
    do: dgettext("dashboard_meeting_form", "Please select a video provider for video meetings")

  defp error_message(:invalid_duration),
    do: dgettext("dashboard_meeting_form", "Duration must be a valid number")

  defp error_message(:invalid_price),
    do: dgettext("dashboard_meeting_form", "Enter a valid price for this meeting type")

  defp error_message(:insufficient_plan),
    do: dgettext("dashboard_meeting_form", "Custom booking questions are available on Pro plans.")

  defp error_message(:feature_access_checker_failed),
    do:
      dgettext(
        "dashboard_meeting_form",
        "Unable to verify subscription status. Please try again."
      )

  defp error_message(_reason),
    do: dgettext("dashboard_meeting_form", "Failed to save meeting type")
end
