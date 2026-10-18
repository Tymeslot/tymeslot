defmodule TymeslotWeb.Themes.Paper.Scheduling.Components.OverviewComponent do
  @moduledoc """
  Paper's overview, the first screen a visitor sees: the same wide card as
  the schedule step's month (`paper-card--wide`), in two panes.

  On the left the organiser's introduction, left-aligned: their avatar (or,
  when they have uploaded a logo, the logo in the brand row above and no
  avatar), the page's heading and instruction (in Paper's voice,
  `Paper.Voice`, which greets nobody; an organiser's own greeting still
  shows). On the right the
  meeting types as one bordered list, each row with its name, approval
  pill and description, then its facts with their icons: length, each
  location (`MeetingTypes.location_options/1`, drawn with
  `LocationIcons.icon/1`) and, for a paid type, its price, then, for a
  group type, how many people it takes (`GroupSession.hint`). With no
  meeting types the right pane says so.

  The card lays the panes out by its own width (`overview.css`, the frame
  shared with the schedule step in `base.css`): the introduction above the
  list on a narrow card, beside it with the schedule step's rule between
  them once both fit, so the rule stays put going on to the next step.

  Choosing a row goes straight on to the schedule screen, the journey's
  second moment (`choose_duration`); back there, the row the visitor chose
  stays marked (`aria-current`). The rows keep the test ids the shared
  suites and the visual harness drive: `duration-option` with
  `data-duration`.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Helpers.LocationIcons
  alias TymeslotWeb.Themes.Paper.Components
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    name = Profiles.display_name(assigns.organizer_profile)

    assigns =
      assign(assigns,
        heading: BookingText.heading(assigns.organizer_profile, :paper, name),
        greeting: BookingText.greeting(assigns.organizer_profile, name, :paper),
        instruction: BookingText.instruction(assigns.organizer_profile, :paper),
        logo: Components.logo(assigns.theme_tokens)
      )

    ~H"""
    <section
      id={"#{@moment}-step"}
      class="paper-card paper-card--wide booker-card"
      data-locale={@locale}
      data-testid="paper-overview"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <Components.brand theme_tokens={@theme_tokens} />

      <div class="paper-overview">
        <header class="paper-intro">
          <Components.avatar :if={is_nil(@logo)} profile={@organizer_profile} size={:lg} />
          <h1 class="paper-title">{@heading}</h1>
          <p :if={@greeting} class="paper-intro__greeting">{@greeting}</p>
          <p :if={@instruction} class="paper-intro__instruction">{@instruction}</p>
        </header>

        <div class="paper-choices">
          <div :if={@meeting_types == []} class="paper-empty">
            <p class="paper-empty__title">{dgettext("booking", "No meeting types available")}</p>
            <p class="paper-empty__text">{dgettext("booking", "Please contact the organiser")}</p>
          </div>

          <ul :if={@meeting_types != []} class="paper-types" role="list">
            <li :for={meeting_type <- @meeting_types} class="paper-types__item">
              <.meeting_type_row
                meeting_type={meeting_type}
                slug={MeetingTypes.effective_slug(meeting_type)}
                selected_duration={@selected_duration}
                price={BookingText.price_label(meeting_type, @host_currency, @locale)}
                target={@myself}
              />
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  attr :meeting_type, :map, required: true
  attr :slug, :string, required: true
  attr :selected_duration, :string, default: nil
  attr :price, :string, default: nil
  attr :target, :any, required: true

  defp meeting_type_row(assigns) do
    assigns =
      assign(assigns,
        description: description(assigns.meeting_type),
        locations: MeetingTypes.location_options(assigns.meeting_type)
      )

    ~H"""
    <button
      type="button"
      class="paper-type"
      phx-click="choose_duration"
      phx-value-duration={@slug}
      phx-target={@target}
      data-testid="duration-option"
      data-duration={@slug}
      data-fact="meeting_type"
      data-value={@slug}
      aria-current={if @selected_duration == @slug, do: "true"}
    >
      <span class="paper-type__main">
        <span class="paper-type__name">
          {@meeting_type.name}
          <ApprovalNotice.pill :if={Approval.required?(@meeting_type)} />
        </span>
        <span :if={@description} class="paper-type__description">{@description}</span>
        <%!-- Spans, not a list: a button holds phrasing content only. --%>
        <span class="paper-facts paper-type__meta">
          <Components.fact tag="span" icon="hero-clock">
            <span class="paper-type__duration">
              {LocalizationHelpers.format_duration(@meeting_type.duration_minutes)}
            </span>
          </Components.fact>
          <Components.fact
            :for={location <- @locations}
            tag="span"
            icon={LocationIcons.icon(location.kind)}
            data-testid="paper-type-location"
          >
            {location.label}
          </Components.fact>
          <Components.fact :if={@price} tag="span" icon="hero-banknotes">
            <span class="paper-type__price">{@price}</span>
          </Components.fact>
        </span>
        <GroupSession.hint meeting_type={@meeting_type} />
      </span>
      <.icon name="hero-chevron-right-mini" class="paper-type__chevron" />
    </button>
    """
  end

  # A demo persona's meeting type is a plain map, so the field is read with
  # Map.get; a blank description is left out rather than drawn empty.
  defp description(meeting_type) do
    case Map.get(meeting_type, :description) do
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: text
      _none -> nil
    end
  end
end
