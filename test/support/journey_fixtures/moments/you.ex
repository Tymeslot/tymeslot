defmodule TymeslotWeb.Test.JourneyFixtures.Moments.You do
  @moduledoc """
  The journey fixtures' attendee moment: the day and time chosen, the
  location choice when the meeting type offers several, the shared booking
  form with the guest field, the approval notice for a type the organiser
  must accept, the submit control (named as every theme names it) and, on a
  paged journey, the way back.

  A moment that collects the answers beside the attendee (Fixture Express)
  first asks the meeting type's questions, one at a time through the shared
  inputs, with Continue; the form follows once the visitor has confirmed the
  answers with Continue past the last question (`Engine.confirmed?/1`), so an
  optional question after a required one is still shown.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.BookingLabels
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.BookingForm
  alias TymeslotWeb.Themes.Shared.Components.GuestField
  alias TymeslotWeb.Themes.Shared.Components.LocationField
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Answers
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @question_events ~w(answer multi_toggle)

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def handle_event(event, params, socket) when event in @question_events,
    do: Events.handle_event(event, params, socket)

  def handle_event(event, params, socket), do: StepEvents.handle_event(event, params, socket)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, paged: Markup.paged?(assigns), asking: asking?(assigns))
    assigns = if assigns.asking, do: Events.assign_render_state(assigns), else: assigns

    Markup.moment_root(assigns, &body/1)
  end

  defp body(assigns) do
    ~H"""
    <JourneyComponents.moment_heading
      moment={@moment}
      moment_state={@moment_state}
      focus={assigns[:journey_focus]}
    >
      Your details
    </JourneyComponents.moment_heading>
    <p data-testid="journey-fixture-slot">
      {LocalizationHelpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
    </p>
    <%= if @asking do %>
      <div data-testid="journey-fixture-questions">
        <p>{@definition["label"]}</p>
        <InputRenderer.render definition={@definition} value={@value} myself={@myself} />
        <p :if={@error} class="form-field__error">{@error}</p>
        <button type="button" phx-click="next_step" phx-target={@myself} data-intent="continue">
          Continue
        </button>
      </div>
    <% else %>
      <.details {assigns} />
    <% end %>
    <button
      :if={@paged}
      type="button"
      phx-click="back_step"
      phx-target={@myself}
      data-intent="back"
    >
      Back
    </button>
    """
  end

  # This moment asks the questions itself when it collects the answers and
  # this booking has some not yet confirmed; otherwise another moment asked
  # them, or there are none.
  defp asking?(%{journey: %Journey{} = journey, moment: key} = assigns) do
    case Journey.moment(journey, key) do
      %Moment{collects: collects} ->
        :answers in collects and Answers.required?(assigns) and
          not Engine.confirmed?(assigns.engine)

      nil ->
        false
    end
  end

  defp asking?(_assigns), do: false

  defp details(assigns) do
    ~H"""
    <LocationField.location_field
      :if={BookingLocation.choice_required?(assigns)}
      location_options={@location_options}
      selected_location_id={@selected_location_id}
      video_choices={BookingLocation.video_choices(assigns)}
      selected_video_id={@selected_video_id}
      location_phone={@location_phone}
      location_error={@location_error}
      phone_required={BookingLocation.phone_required?(assigns)}
      target={@myself}
    />
    <BookingForm.booking_form form={@form} validation_errors={@validation_errors} target={@myself}>
      <GuestField.guest_field
        :if={GuestBooking.guests_allowed?(assigns)}
        guest_emails={@guest_emails}
        guest_input={@guest_input}
        guest_error={@guest_error}
        guests_open={@guests_open}
        max_guests={@max_guests}
        target={@myself}
      />
    </BookingForm.booking_form>
    <ApprovalNotice.block
      :if={Approval.required?(@meeting_type)}
      organizer_name={Profiles.display_name(@organizer_profile)}
      payment_required={@meeting_type.payment_required}
      stage={:before}
    />
    <button type="submit" form="booking-form" data-intent="submit" data-testid="submit-booking">
      {BookingLabels.submit_label(
        assigns[:is_rescheduling] || false,
        @meeting_type,
        "Book",
        theme_key(@theme_id)
      )}
    </button>
    """
  end

  # The moment is shared by the journey fixtures, so each page speaks for the
  # theme it is rendering.
  defp theme_key(theme_id) do
    {:ok, key} = Catalog.id_to_key(theme_id)
    key
  end
end
