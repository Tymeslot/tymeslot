defmodule Tymeslot.Emails.EmailService.SeriesEmails do
  @moduledoc """
  The emails a booking series sends as one: its confirmation, its
  cancellation, and for a series held for approval its request and the
  answer when it is declined or expires.
  """

  alias Tymeslot.Emails.Delivery

  alias Tymeslot.Emails.Templates.{
    SeriesCancellation,
    SeriesConfirmation,
    SeriesRequest,
    SeriesRequestOutcome
  }

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

  @doc "Sends a series request to the organiser, or its acknowledgement to the booker."
  @spec send_series_request(:attendee | :organizer, String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_series_request(role, email, series_details),
    do: Delivery.deliver(SeriesRequest.render(role, email, series_details))

  @doc "Tells the booker their series request was declined or expired."
  @spec send_series_request_outcome(:declined | :expired, String.t(), map()) ::
          {:ok, any()} | {:error, any()}
  def send_series_request_outcome(variant, email, series_details),
    do: Delivery.deliver(SeriesRequestOutcome.render(variant, email, series_details))
end
