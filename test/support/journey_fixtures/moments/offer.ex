defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Offer do
  @moduledoc """
  The journey fixtures' meeting-type moment: a button per meeting type for the
  meeting type fact, with the approval pill on a type the organiser must
  accept. Once answered, a transcript shows the answer and, where it may be
  changed, an Edit control instead. A meeting type a direct or private link
  chose may not be changed (`Markup.revisitable?/1`): the moment then names
  the chosen type alone, never the organiser's public list beside it. The
  chosen type keeps its approval pill, so a visitor whose type was chosen for
  them (a defaulted only type) still learns it needs approval. A transcript
  opens with the organiser's name, as the first line of the conversation.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    done = assigns.moment_state == :done

    assigns
    |> assign(
      transcript: Markup.transcript?(assigns),
      answered: Markup.transcript?(assigns) and done,
      locked: done and not Markup.revisitable?(assigns),
      editable: Markup.revisitable?(assigns)
    )
    |> Markup.moment_root(&body/1)
  end

  defp body(assigns) do
    ~H"""
    <p :if={@transcript} data-testid="journey-fixture-host">
      {Profiles.display_name(@organizer_profile)}
    </p>
    <%= cond do %>
      <% @answered -> %>
        <p data-testid="journey-fixture-answer">
          {@meeting_type && @meeting_type.name}
          <ApprovalNotice.pill :if={Approval.required?(@meeting_type)} />
        </p>
        <button
          :if={@editable}
          type="button"
          phx-click="navigate_to_step"
          phx-value-step={@moment}
          data-intent="edit"
        >
          Change meeting type
        </button>
      <% @locked -> %>
        <p data-testid="journey-fixture-answer">
          {@meeting_type && @meeting_type.name}
          <ApprovalNotice.pill :if={Approval.required?(@meeting_type)} />
        </p>
      <% true -> %>
        <JourneyComponents.moment_heading
          moment={@moment}
          moment_state={@moment_state}
          focus={assigns[:journey_focus]}
        >
          What would you like to book?
        </JourneyComponents.moment_heading>
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
    <% end %>
    """
  end
end
