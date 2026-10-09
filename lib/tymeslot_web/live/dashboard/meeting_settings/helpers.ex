defmodule TymeslotWeb.Dashboard.MeetingSettings.Helpers do
  @moduledoc """
  Helper functions shared by the meeting settings components.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Phoenix.Component
  alias Tymeslot.Profiles
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers

  @doc """
  Reloads the profile if necessary to ensure fresh data.
  """
  @spec maybe_reload_profile(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_reload_profile(socket) do
    # If we have a profile and a current user, reload to ensure fresh data
    if socket.assigns[:profile] && socket.assigns[:current_user] do
      fresh_profile = Profiles.get_profile(socket.assigns.current_user.id)
      Component.assign(socket, :profile, fresh_profile || socket.assigns.profile)
    else
      socket
    end
  end

  @doc """
  Gets security metadata from socket assigns using the centralized dashboard helper.
  """
  @spec get_security_metadata(Phoenix.LiveView.Socket.t()) :: map()
  def get_security_metadata(socket) do
    DashboardHelpers.get_security_metadata(socket)
  end

  @doc """
  The meeting-type form's errors from a refused changeset, keyed by field
  and translated through the `errors` domain like any other form error
  (`Forms.translate_error/1`).
  """
  @spec changeset_form_errors(Changeset.t()) :: %{atom() => [String.t()]}
  def changeset_form_errors(%Changeset{} = changeset),
    do: Changeset.traverse_errors(changeset, &Forms.translate_error/1)

  @doc """
  Formats error messages that can be either strings or lists.
  """
  @spec format_errors(list() | String.t() | any()) :: String.t()
  def format_errors(errors) when is_list(errors), do: Enum.join(errors, ", ")
  def format_errors(error) when is_binary(error), do: error
  def format_errors(_other), do: dgettext("dashboard_meeting_form", "An error occurred")
end
