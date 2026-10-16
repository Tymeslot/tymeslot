defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.ConfirmationStep do
  @moduledoc """
  The fixture theme's confirmation step: what every theme tells the booker
  (whether the booking is held for approval or confirmed, the address the
  details went to, the meeting's length, and the approval notice while it is
  held), unstyled, and a fresh start.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Shared.ApprovalDisplay
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.ConfirmationText
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="fixture-confirmation">
      <h1 data-testid="confirmation-heading">{headline(assigns)}</h1>
      <p data-testid="fixture-confirmation-email">{@email}</p>
      <p data-testid="fixture-confirmation-length">
        {Offer.duration_minutes(@meeting_type, @duration)} min
      </p>
      <ApprovalNotice.block
        :if={ApprovalDisplay.awaiting_approval?(assigns)}
        organizer_name={Profiles.display_name(@organizer_profile)}
        stage={:after}
      />
      <button type="button" phx-click="schedule_another" phx-target={@myself} data-intent="restart">
        Again
      </button>
    </section>
    """
  end

  # Which status applies is decided in `ConfirmationText`, as on every theme
  # (a held request is never announced as a confirmed meeting); the words are
  # the fixture's own, the held one as the shipped themes put it.
  defp headline(assigns) do
    case ConfirmationText.status(assigns) do
      :held -> "Request sent!"
      :rescheduled -> "Rescheduled"
      :confirmed -> "Confirmed"
    end
  end
end
