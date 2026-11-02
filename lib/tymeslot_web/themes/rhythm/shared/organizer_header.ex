defmodule TymeslotWeb.Themes.Rhythm.Shared.OrganizerHeader do
  @moduledoc """
  Shared organizer profile header component for the Rhythm theme.
  Displays organizer avatar, name, and meeting duration, and marks a group
  type as a group session and a paid type with its price on every step it
  heads.

  "Schedule with" and the organiser's name are the heading of the step it
  heads (`Journey.Components.moment_heading/1`), so the step takes the focus
  there when the visitor moves on to it; it looks as the two lines did.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.{Demo, Profiles}
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.MeetingPrice
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents

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
  - moment, moment_state, focus: the step's moment, its state and the
    `:journey_focus` assign, for the heading
  """
  attr :organizer_profile, :map, required: true
  attr :meeting_type, :map, default: nil
  attr :selected_duration, :string, default: nil
  attr :length_minutes, :integer, default: nil
  attr :host_currency, :string, default: nil
  attr :show_price, :boolean, default: true
  attr :locale, :string, required: true
  attr :moment, :atom, default: nil
  attr :moment_state, :atom, default: nil
  attr :focus, :atom, default: nil

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
        <JourneyComponents.moment_heading
          tag="h1"
          moment={@moment}
          moment_state={@moment_state}
          focus={@focus}
          class="organizer-heading"
        >
          <span class="organizer-name">{dgettext("booking", "Schedule with")}</span>
          <span class="organizer-name-full">
            {Profiles.display_name(@organizer_profile) || ""}
          </span>
        </JourneyComponents.moment_heading>
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
