defmodule Tymeslot.Bookings.Submitter do
  @moduledoc """
  The contract between the public booking page and whatever processes its
  submission: `Tymeslot.Bookings.Orchestrator` books for real, and
  `Tymeslot.Bookings.DemoOrchestrator` simulates a booking for previews and
  demo pages. The page picks one (`Tymeslot.Demo.get_orchestrator/1`) and calls
  `submit_booking/2` on it, so both must answer in the shapes it handles.
  """

  @doc """
  Processes a booking submission (`form_data`, `meeting_params`, and for a
  reschedule its uid or seat token).

  Returns the booked meeting, a payment hand-off for a paid meeting type, or a
  reason the web layer renders
  (`TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage`).
  """
  @callback submit_booking(params :: map(), opts :: keyword()) ::
              {:ok, term()}
              | {:ok, :payment_required, %{meeting: map(), checkout_url: String.t()}}
              | {:error, term()}
end
