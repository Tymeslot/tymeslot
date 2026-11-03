defmodule Tymeslot.Notifications.Email.PlannedSessionEmails do
  @moduledoc """
  The organiser's participant list for a planned session
  (`Tymeslot.Meetings.PlannedSessions`), sent when its registration closes
  (`Tymeslot.Emails.Templates.RegistrationClosed`).

  The job is scheduled for the closing time when the session is planned
  (`Tymeslot.Emails.EmailScheduler.SessionScheduler`) and re-reads the
  session when it runs. A session that has since been cancelled, or whose
  time no longer holds, gets no list. One whose registration now closes
  later (it was moved) waits until then.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Notifications.Email.SeatJobs
  alias Tymeslot.Repo
  alias Tymeslot.Workers.DeliveryClaims

  @not_a_session "Meeting is not a planned session"
  @session_void "Session cancelled or its time no longer holds"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason), do: reason in [@not_a_session, @session_void]

  @spec handle_registration_closed(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()} | {:snooze, pos_integer()}
  def handle_registration_closed(%{"meeting_id" => meeting_id}, job_id) do
    MeetingEmails.with_meeting(meeting_id, "registration closed email", fn meeting ->
      cond do
        not meeting.planned ->
          {:discard, @not_a_session}

        MeetingState.slot_void?(meeting) ->
          Logger.info("Skipping participant list of a void session", meeting_id: meeting_id)
          {:discard, @session_void}

        PlannedSessions.open?(meeting) ->
          {:snooze, seconds_until_close(meeting)}

        true ->
          DeliveryClaims.once(job_id, "organizer", fn -> send_list(meeting) end)
      end
    end)
  end

  defp send_list(%MeetingSchema{} = meeting) do
    participants =
      meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Repo.preload(:guests)

    details =
      meeting
      |> AppointmentBuilder.for_organizer_of_group(length(participants))
      |> Map.put(:capacity, meeting.capacity)

    roster =
      Gettext.with_locale(TymeslotWeb.Gettext, RecipientLocale.organizer_locale(details), fn ->
        Enum.map(participants, &entry(&1, meeting.custom_fields_snapshot))
      end)

    meeting.organizer_email
    |> Config.email_service_module().send_registration_closed(details, roster)
    |> SeatJobs.send_result("registration closed", meeting_id: meeting.id)
  end

  defp entry(participant, questions) do
    answers = participant.custom_field_answers || %{}

    %{
      name: participant.name,
      email: participant.email,
      phone: participant.phone,
      company: participant.company,
      message: participant.message,
      # A guest who declined is not coming, so the list leaves them out.
      guests:
        for(
          guest <- participant.guests,
          guest.status != :declined,
          do: %{name: guest.name, email: guest.email}
        ),
      answers:
        questions
        |> Enum.map(&{&1["label"] || "", AnswerRenderer.render(&1, answers[&1["id"]])})
        |> Enum.reject(fn {_label, value} -> value == "" end)
    }
  end

  defp seconds_until_close(meeting) do
    meeting
    |> PlannedSessions.registration_closes_at()
    |> DateTime.diff(Clock.utc_now())
    |> max(1)
  end
end
