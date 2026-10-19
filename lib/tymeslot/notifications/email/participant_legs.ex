defmodule Tymeslot.Notifications.Email.ParticipantLegs do
  @moduledoc """
  The organiser's and the attendee's copy of a booking notice (a reschedule,
  a cancellation), each claimed for the job (`DeliveryClaims`).

  A copy that fails fails the job, and Oban's retry sends only the copy that
  has not gone out, rather than discarding a half-sent pair or sending both
  again.

  A job from older code claimed the pair as one, under
  `"<notice>:participants"`; when it holds that claim, both copies went out
  and neither is sent again.
  """

  alias Tymeslot.Notifications.Email.DeliveryOutcome
  alias Tymeslot.Workers.DeliveryClaims

  @type send_fun :: (-> {:ok, term()} | {:error, term()})

  @doc """
  Sends `notice`'s two copies for `meeting_id`, each at most once per job.

  Returns `:ok` once both have gone out, or the error to retry the job on
  (see `DeliveryOutcome.from_results/3`).
  """
  @spec deliver(DeliveryClaims.job_id(), String.t(), term(), send_fun(), send_fun()) ::
          :ok | {:error, term()}
  def deliver(job_id, notice, meeting_id, organizer_send, attendee_send) do
    if DeliveryClaims.claimed?(job_id, "#{notice}:participants") do
      :ok
    else
      DeliveryOutcome.from_results(notice, [meeting_id: meeting_id], [
        DeliveryClaims.once(job_id, "#{notice}:organizer", organizer_send),
        DeliveryClaims.once(job_id, "#{notice}:attendee", attendee_send)
      ])
    end
  end
end
