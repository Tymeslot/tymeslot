defmodule TymeslotWeb.Themes.Rhythm.Shared.OrganizerHeader do
  @moduledoc """
  Shared organizer profile header component for the Rhythm theme.
  Displays organizer avatar, name, and meeting duration, and marks a group
  type as a group session and a paid type with its price on every step it
  heads.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.{Demo, Profiles}
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.MeetingPrice

  @doc """
  Renders a small organizer profile header.

  ## Attributes
  - organizer_profile: The organizer profile to display
  - meeting_type: Optional meeting type (for duration)
  - selected_duration: Optional selected duration (fallback if no meeting_type)
  - length_minutes: The length the booker chose, when the type offers several
  - host_currency: The currency a paid meeting type's price is shown in
  - show_price: Whether to show that price (a reschedule is never charged)
  - locale: The page's locale, for writing the price
  """
  attr :organizer_profile, :map, required: true
  attr :meeting_type, :map, default: nil
  attr :selected_duration, :string, default: nil
  attr :length_minutes, :integer, default: nil
  attr :host_currency, :string, default: nil
  attr :show_price, :boolean, default: true
  attr :locale, :string, required: true

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
        <div class="organizer-name">{dgettext("booking", "Schedule with")}</div>
        <div class="organizer-name-full">
          {Profiles.display_name(@organizer_profile) || ""}
        </div>
        <div class="meeting-duration">
          {BookingText.duration_label(%{
            meeting_type: @meeting_type,
            duration: @selected_duration,
            chosen_length_minutes: @length_minutes
          })}
        </div>
        <GroupSession.hint :if={@meeting_type} meeting_type={@meeting_type} />
        <MeetingPrice.hint
          :if={@meeting_type && @show_price}
          meeting_type={@meeting_type}
          currency={@host_currency}
          locale={@locale}
        />
      </div>
    </div>
    """
  end
end
