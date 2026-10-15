defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Pick do
  @moduledoc """
  Fixture Two's second screen: one moment on a paged journey collecting the
  slot, the answers and the attendee. The month calendar and the day's
  times; once a time is picked, the meeting type's questions, all at once,
  above the details (`You.details/1`), and one submit sends both.

  The details' form exists only once a time is picked: the runtime puts the
  attendee's entry off until the slot is known (`Runtime.enter_ready/1`).
  The answers are no prerequisite of the details here
  (`Facts.Attendee.requires/1`): each answer names its question as it is
  given, and the submission validates them all and names each one that
  fails (`CustomQuestions.Events.all_questions/1`). There is no way on, so
  the `next_step` a question's form sends on Enter is dropped and the
  questions never step; Back returns to the meeting types.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Test.JourneyFixtures.Moments.You
  alias TymeslotWeb.Themes.Shared.Blocks.MonthCalendar
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.StepEvents

  @question_events ~w(answer multi_toggle)

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def handle_event(event, params, socket) when event in @question_events,
    do: Events.handle_event(event, params, socket)

  # Enter in a question's field submits its form with `next_step`. This
  # screen has no way on, and stepping the questions would make Back step
  # back through them, so it is dropped.
  def handle_event("next_step", _params, socket), do: {:noreply, socket}

  def handle_event(event, params, socket), do: StepEvents.handle_event(event, params, socket)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        picked: is_binary(assigns.selected_date) and is_binary(assigns.selected_time),
        questions: Events.all_questions(assigns)
      )

    ~H"""
    <section
      id={"#{@moment}-step"}
      class="booker-card"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
      >
        Pick a time
      </JourneyComponents.moment_heading>
      <MonthCalendar.month_calendar
        current_year={@current_year}
        current_month={@current_month}
        user_timezone={@user_timezone}
        first_day={@week_start}
        selected_date={@selected_date}
        availability_status={@availability_status}
        booking_window_days={assigns[:booking_window_days]}
        organizer_profile={@organizer_profile}
        month_availability_map={@month_availability_map}
        meeting_type={@meeting_type}
        target={@myself}
      />
      <SlotList.slot_list
        selected_date={@selected_date}
        selected_time={@selected_time}
        available_slots={@available_slots}
        loading_slots={@loading_slots}
        calendar_error={@calendar_error}
        slot_interval_minutes={@slot_interval_minutes}
        duration_minutes={@duration_minutes}
        expanded_hour={@expanded_hour}
        target={@myself}
      />
      <div :if={@picked and @questions != []} data-testid="journey-fixture-questions">
        <div :for={question <- @questions} data-testid="journey-fixture-question">
          <p>{question.definition["label"]}</p>
          <InputRenderer.render
            definition={question.definition}
            value={question.value}
            myself={@myself}
            autofocus={false}
          />
          <p
            :if={question.error}
            class="form-field__error"
            data-testid="journey-fixture-question-error"
          >
            {question.error}
          </p>
        </div>
      </div>
      <You.details :if={@picked and match?(%Phoenix.HTML.Form{}, assigns[:form])} {assigns} />
      <button type="button" phx-click="back_step" phx-target={@myself} data-intent="back">
        Back
      </button>
    </section>
    """
  end
end
