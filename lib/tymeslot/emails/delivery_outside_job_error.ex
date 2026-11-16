defmodule Tymeslot.Emails.DeliveryOutsideJobError do
  @moduledoc """
  Raised by `Tymeslot.Emails.Delivery.deliver/2` when it is asked to send an
  email outside an email job.

  Every email goes out from an Oban job, which retries a failed send and
  claims each recipient so a retry does not repeat one. A send made inline,
  from a LiveView, a controller, or a job that is not an email job, has
  neither: when it fails the email is lost, and nothing records it. Schedule
  the email through `Tymeslot.Emails.EmailScheduler` instead, and send it
  from the job's handler.
  """

  defexception message:
                 "email sent outside an email job: schedule it through " <>
                   "Tymeslot.Emails.EmailScheduler and send it from the job, which " <>
                   "wraps its work in Tymeslot.Emails.Delivery.within_job/2"
end
