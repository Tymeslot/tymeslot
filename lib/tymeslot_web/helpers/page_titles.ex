defmodule TymeslotWeb.Helpers.PageTitles do
  @moduledoc """
  Helper module for managing page titles across the application.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Returns the page title for dashboard sections.
  """
  @spec dashboard_title(atom()) :: String.t()
  def dashboard_title(:overview), do: section_title(dgettext("dashboard_common", "Overview"))
  def dashboard_title(:settings), do: section_title(dgettext("dashboard_common", "Settings"))

  def dashboard_title(:availability),
    do: section_title(dgettext("dashboard_common", "Availability"))

  def dashboard_title(:account), do: section_title(dgettext("dashboard_common", "Account"))

  def dashboard_title(:meeting_settings),
    do: section_title(dgettext("dashboard_common", "Meeting Settings"))

  # The calendar is the dashboard's landing mode, so it carries the bare title.
  def dashboard_title(:calendar), do: dgettext("dashboard_common", "Dashboard")

  def dashboard_title(:calendar_integration),
    do: section_title(dgettext("dashboard_common", "Calendar Integration"))

  def dashboard_title(:video_integration),
    do: section_title(dgettext("dashboard_common", "Video Integration"))

  def dashboard_title(:automation), do: section_title(dgettext("dashboard_common", "Automation"))
  def dashboard_title(:theme), do: section_title(dgettext("dashboard_common", "Theme Selection"))
  def dashboard_title(:meetings), do: section_title(dgettext("dashboard_common", "Meetings"))
  def dashboard_title(:embed), do: section_title(dgettext("dashboard_common", "Embed & Share"))
  def dashboard_title(:payments), do: section_title(dgettext("dashboard_common", "Payments"))

  def dashboard_title(action) do
    # Check if this action is registered via dynamic extensions
    extensions = Application.get_env(:tymeslot, :dashboard_sidebar_extensions, [])

    case Enum.find(extensions, &(&1.action == action)) do
      %{label: label} -> section_title(label)
      _extension -> dgettext("dashboard_common", "Dashboard")
    end
  end

  # Formats a section label as "<section> - Dashboard". The suffix lives in a
  # single msgid so translators localise it once, not per section.
  defp section_title(label) do
    dgettext("dashboard_common", "%{section} - Dashboard", section: label)
  end
end
