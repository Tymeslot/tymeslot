defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.OfferMoment do
  @moduledoc """
  The ways to work with the organiser: the page's heading (the organiser's
  own, or Folio's voice, "Ways to work with me"), the instruction when the
  organiser wrote one, and each meeting type as a full-width entry with its
  name and approval pill, the facts a guest decides on (its length, each
  place it is held, `MeetingTypes.location_options/1`, and for a paid type
  its price), a group type's size (`GroupSession.hint`) and its whole
  description, a button for the meeting type fact
  (`data-fact="meeting_type"`, `aria-current` on the chosen one). Choosing
  one opens the calendar below by itself; the list stays, so another choice
  reopens the calendar for it. A type a direct or private link chose cannot
  be changed (`Journey.revisitable?/2`): the moment then shows that type
  alone, as text (`folio-meeting--chosen`), never the organiser's public
  list.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Helpers.LocationIcons
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    profile = assigns.organizer_profile

    assigns =
      assign(assigns,
        heading: BookingText.heading(profile, :folio, Profiles.display_name(profile)),
        instruction: BookingText.instruction(profile, :folio),
        locked: locked?(assigns)
      )

    ~H"""
    <section
      id={"#{@moment}-step"}
      class="folio-section folio-offer booker-card"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
        class="folio-section__title"
      >
        {@heading}
      </JourneyComponents.moment_heading>
      <p :if={@instruction} class="folio-muted">{@instruction}</p>

      <%= cond do %>
        <% @locked -> %>
          <div class="folio-meeting folio-meeting--chosen">
            <.entry
              meeting_type={@meeting_type}
              price={BookingText.price_label(@meeting_type, @host_currency, @locale)}
            />
          </div>
        <% @meeting_types == [] -> %>
          <div class="folio-empty">
            <p class="folio-empty__title">
              {dpgettext("booking_voice", "folio", "I'm not taking new bookings at the moment.")}
            </p>
          </div>
        <% true -> %>
          <ul class="folio-meetings">
            <li :for={meeting_type <- @meeting_types}>
              <% slug = MeetingTypes.effective_slug(meeting_type) %>
              <button
                type="button"
                class="folio-meeting"
                phx-click="select_duration"
                phx-value-duration={slug}
                phx-target={@myself}
                data-testid="duration-option"
                data-duration={slug}
                data-fact="meeting_type"
                data-value={slug}
                aria-current={if @selected_duration == slug, do: "true"}
              >
                <.entry
                  meeting_type={meeting_type}
                  price={BookingText.price_label(meeting_type, @host_currency, @locale)}
                />
              </button>
            </li>
          </ul>
      <% end %>
    </section>
    """
  end

  attr :meeting_type, :map, required: true
  attr :price, :string, default: nil

  # Spans, not a list: a button holds phrasing content only.
  defp entry(assigns) do
    assigns = assign(assigns, :locations, MeetingTypes.location_options(assigns.meeting_type))

    ~H"""
    <span class="folio-meeting__name">
      {@meeting_type.name}
      <ApprovalNotice.pill :if={Approval.required?(@meeting_type)} />
    </span>
    <span class="folio-meeting__facts">
      <span class="folio-meeting__duration">
        {LocalizationHelpers.format_duration(@meeting_type.duration_minutes)}
      </span>
      <span
        :for={location <- @locations}
        class="folio-meeting__location"
        data-testid="folio-meeting-location"
      >
        <.icon name={LocationIcons.icon(location.kind)} class="folio-meeting__icon" />
        {location.label}
      </span>
      <span :if={@price} class="folio-meeting__price">{@price}</span>
    </span>
    <GroupSession.hint meeting_type={@meeting_type} class="folio-meeting__group" />
    <span :if={present?(Map.get(@meeting_type, :description))} class="folio-meeting__description">
      {@meeting_type.description}
    </span>
    """
  end

  # A meeting type is known and the visitor may not change it (a direct or
  # private link): the moment names it alone.
  defp locked?(%{journey: %Journey{} = journey, moment: key, meeting_type: %{}} = assigns) do
    assigns.moment_state == :done and
      not Journey.revisitable?(Journey.moment(journey, key), assigns)
  end

  defp locked?(_assigns), do: false

  defp present?(text), do: is_binary(text) and String.trim(text) != ""
end
