defmodule TymeslotWeb.Helpers.PageTitles do
  @moduledoc """
  Helper module for managing page titles across the application.
  """

  @doc """
  Returns the page title for dashboard sections.
  """
  @spec dashboard_title(atom()) :: String.t()
  def dashboard_title(:overview), do: "Dashboard"
  def dashboard_title(:settings), do: "Settings - Dashboard"
  def dashboard_title(:availability), do: "Availability - Dashboard"
  def dashboard_title(:account), do: "Account - Dashboard"
  def dashboard_title(:meeting_settings), do: "Meeting Settings - Dashboard"
  def dashboard_title(:calendar), do: "Calendar Integration - Dashboard"
  def dashboard_title(:video), do: "Video Integration - Dashboard"
  def dashboard_title(:automation), do: "Automation - Dashboard"
  def dashboard_title(:theme), do: "Theme Selection - Dashboard"
  def dashboard_title(:meetings), do: "Meetings - Dashboard"
  def dashboard_title(:embed), do: "Embed & Share - Dashboard"

  def dashboard_title(action) do
    # Check if this action is registered via dynamic extensions
    extensions = Application.get_env(:tymeslot, :dashboard_sidebar_extensions, [])

    case Enum.find(extensions, &(&1.action == action)) do
      %{label: label} -> "#{label} - Dashboard"
      _extension -> "Dashboard"
    end
  end
end
