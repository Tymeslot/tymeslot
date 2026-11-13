defmodule Tymeslot.Emails.EmailService.SeriesEmails do
  @moduledoc "The emails a booking series sends as one: its confirmation and its cancellation."

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.Templates.{SeriesCancellation, SeriesConfirmation}

  @doc "Sends the series confirmation to the booker (`:attendee`) or the organiser."
  @spec send_series_confirmation(:attendee | :organizer, String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_series_confirmation(role, email, series_details),
    do: Delivery.deliver(SeriesConfirmation.render(role, email, series_details))

  @doc "Sends the cancellation of several series sessions to the booker or the organiser."
  @spec send_series_cancellation(:attendee | :organizer, String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_series_cancellation(role, email, series_details),
    do: Delivery.deliver(SeriesCancellation.render(role, email, series_details))
end
