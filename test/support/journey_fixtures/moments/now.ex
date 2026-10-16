defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Now do
  @moduledoc """
  Fixture Express's first screen: the soonest free times (`NextSlots`), the
  meeting type already chosen by the moment's default (named, with its
  approval pill, when the organiser offers only it), a switcher above the
  times when the organiser has more than one type, and Continue. A meeting
  type a direct or private link chose may not be changed
  (`Markup.revisitable?/1`): the moment then names it alone, never the
  organiser's other types.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.Blocks.NextSlots
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns
    |> assign(:switcher, length(assigns.meeting_types) > 1 and Markup.revisitable?(assigns))
    |> Markup.moment_root(&body/1)
  end

  defp body(assigns) do
    ~H"""
    <JourneyComponents.moment_heading
      moment={@moment}
      moment_state={@moment_state}
      focus={assigns[:journey_focus]}
    >
      Next available
    </JourneyComponents.moment_heading>
    <%= if @switcher do %>
      <div role="group" aria-label="Meeting type">
        <button
          :for={meeting_type <- @meeting_types}
          type="button"
          data-testid="duration-option"
          data-fact="meeting_type"
          data-value={MeetingTypes.effective_slug(meeting_type)}
          phx-click="select_duration"
          phx-value-duration={MeetingTypes.effective_slug(meeting_type)}
          phx-target={@myself}
          aria-pressed={to_string(@selected_duration == MeetingTypes.effective_slug(meeting_type))}
        >
          {meeting_type.name}
          <ApprovalNotice.pill :if={Approval.required?(meeting_type)} />
        </button>
      </div>
    <% else %>
      <p :if={@meeting_type} data-testid="journey-fixture-answer">
        {@meeting_type.name}
        <ApprovalNotice.pill :if={Approval.required?(@meeting_type)} />
      </p>
    <% end %>
    <NextSlots.next_slots
      id={"#{@moment}-slots"}
      week_slots={@week_slots}
      loading={@week_slots_loading}
      error={@week_slots_error}
      user_timezone={@user_timezone}
      selected_date={@selected_date}
      selected_time={@selected_time}
      target={@myself}
    />
    <%!-- Enabled before a time is picked: `Paged` keeps the moment and
         flashes why, as for any moment whose facts are not known. --%>
    <button type="button" phx-click="next_step" phx-target={@myself} data-intent="continue">
      Continue
    </button>
    """
  end
end
