defmodule TymeslotWeb.Themes.Paper.Scheduling.Components.OverviewComponent do
  @moduledoc """
  Paper's overview: the organiser's avatar (or nothing, with their logo
  above), the page's heading, greeting and instruction, then the meeting
  types as one plain list, each row with its name, description, length
  and, for a paid type, its price. Choosing a row marks it (`aria-pressed`);
  Next goes on to the schedule step.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Paper.Components
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
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
        greeting: BookingText.greeting(assigns.organizer_profile, name),
        instruction: BookingText.instruction(assigns.organizer_profile),
        logo: Components.logo(assigns.theme_tokens)
      )

    ~H"""
    <section class="paper-card booker-card" data-locale={@locale} data-testid="paper-overview">
      <Components.brand theme_tokens={@theme_tokens} />

      <header class="paper-intro">
        <Components.avatar :if={is_nil(@logo)} profile={@organizer_profile} size={:lg} />
        <h1 class="paper-title">{@heading}</h1>
        <p :if={@greeting} class="paper-intro__greeting">{@greeting}</p>
        <p class="paper-intro__instruction">{@instruction}</p>
      </header>

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

      <div class="paper-actions">
        <button
          type="button"
          class="paper-button paper-button--primary"
          phx-click="next_step"
          phx-target={@myself}
          data-testid="next-step"
          disabled={is_nil(@selected_duration)}
        >
          {dgettext("booking", "Next")}
          <.icon name="hero-arrow-right-mini" class="paper-button__icon" />
        </button>
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
    assigns = assign(assigns, :description, description(assigns.meeting_type))

    ~H"""
    <button
      type="button"
      class="paper-type"
      phx-click="select_duration"
      phx-value-duration={@slug}
      phx-target={@target}
      data-testid="duration-option"
      data-duration={@slug}
      aria-pressed={to_string(@selected_duration == @slug)}
    >
      <span class="paper-type__main">
        <span class="paper-type__name">
          {@meeting_type.name}
          <ApprovalNotice.pill :if={Approval.required?(@meeting_type)} />
        </span>
        <span :if={@description} class="paper-type__description">{@description}</span>
      </span>
      <span class="paper-type__meta">
        <span class="paper-type__duration">
          {LocalizationHelpers.format_duration(@meeting_type.duration_minutes)}
        </span>
        <span :if={@price} class="paper-type__price">{@price}</span>
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
