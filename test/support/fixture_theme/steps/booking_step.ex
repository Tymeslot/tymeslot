defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.BookingStep do
  @moduledoc """
  The fixture theme's booking step: the day and time chosen, the shared
  booking form (`Shared.Components.BookingForm`, with its anti-spam fields),
  a submit button outside it, labelled by the shared `BookingLabels` in the
  rendering theme's voice, and the way back.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.BookingLabels
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.BookingForm
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="fixture-booking">
      <p data-testid="fixture-booking-slot">{@selected_date} {@selected_time}</p>
      <BookingForm.booking_form
        form={@form}
        validation_errors={@validation_errors}
        target={@myself}
      />
      <ApprovalNotice.block
        :if={Approval.required?(@meeting_type)}
        organizer_name={Profiles.display_name(@organizer_profile)}
        payment_required={@meeting_type.payment_required}
        stage={:before}
      />
      <button type="submit" form="booking-form" data-testid="submit-booking" data-intent="submit">
        {BookingLabels.submit_label(
          assigns[:is_rescheduling] || false,
          @meeting_type,
          "Book",
          theme_key(@theme_id)
        )}
      </button>
      <button type="button" phx-click="back_step" phx-target={@myself} data-intent="back">
        Back
      </button>
    </section>
    """
  end

  # The steps are shared by the fixture and the showcase theme, so each page
  # speaks for the theme it is rendering.
  defp theme_key(theme_id) do
    {:ok, key} = Catalog.id_to_key(theme_id)
    key
  end
end
