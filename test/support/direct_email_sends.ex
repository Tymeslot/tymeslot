defmodule Tymeslot.Test.DirectEmailSends do
  @moduledoc """
  For a test module that exercises a send directly (a template's delivery,
  `Tymeslot.Emails.Delivery` itself) rather than through the email job that
  sends it in the application: `setup :allow_direct_sends` lets every send the
  test process makes through `Tymeslot.Emails.Delivery.deliver/2`'s refusal
  of sends outside an email job, for the whole test.

  The mark is `Delivery.allow_outside_job/1`'s, set for the test rather than
  for one function, since a test process ends with the test. A send from any
  other process (a LiveView, a task) is still refused, which is the point.
  """

  # The process key `Tymeslot.Emails.Delivery` reads; a drift between the
  # two makes every test using this helper raise, so it cannot go unnoticed.
  @email_job {Tymeslot.Emails.Delivery, :email_job}

  @doc "A `setup` callback: allows direct sends for the rest of the test."
  @spec allow_direct_sends(map()) :: :ok
  def allow_direct_sends(_context) do
    Process.put(@email_job, :allowed_outside_job)
    :ok
  end
end
