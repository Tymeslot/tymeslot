defmodule TymeslotWeb.Themes.Rhythm.Shared.OrganizerHeader do
  @moduledoc """
  Shared organizer profile header component for the Rhythm theme.
  Displays organizer avatar, name, and meeting duration.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.{Demo, Profiles}
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @doc """
  Renders a small organizer profile header.

  ## Attributes
  - organizer_profile: The organizer profile to display
  - meeting_type: Optional meeting type (for duration)
  - selected_duration: Optional selected duration (fallback if no meeting_type)
  """
  attr :organizer_profile, :map, required: true
  attr :meeting_type, :map, default: nil
  attr :selected_duration, :integer, default: nil

  @spec organizer_header_small(map()) :: Phoenix.LiveView.Rendered.t()
  def organizer_header_small(assigns) do
    ~H"""
    <div class="organizer-profile-small">
      <img
        src={Demo.avatar_url(@organizer_profile, :thumb)}
        alt={Demo.avatar_alt_text(@organizer_profile)}
        class="avatar-image-small"
      />
      <div class="organizer-info-small">
        <div class="organizer-name">{gettext("Schedule with")}</div>
        <div class="organizer-name-full">
          {Profiles.display_name(@organizer_profile) || ""}
        </div>
        <div class="meeting-duration">
          <%= if @meeting_type do %>
            {LocalizationHelpers.format_duration(@meeting_type.duration_minutes)}
          <% else %>
            {LocalizationHelpers.format_duration(@selected_duration)}
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
