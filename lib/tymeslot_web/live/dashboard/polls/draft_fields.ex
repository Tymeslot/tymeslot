defmodule TymeslotWeb.Dashboard.Polls.DraftFields do
  @moduledoc """
  The create form's fields filled from a saved draft, so `PollForm` opens a
  draft as the host left it: its details, its times as rows, and its invitees
  back as the text they were typed from.

  The host chose who can vote when they saved, so the access choice comes back
  as made rather than following the invitee field again.
  """

  alias Tymeslot.Polls.PollSchema
  alias TymeslotWeb.Dashboard.Polls.{CandidateTimes, LocalTime, PollAccess, PollReminders}

  @doc "The `PollForm` assigns for `draft`."
  @spec assigns(PollSchema.t()) :: keyword()
  def assigns(%PollSchema{status: :draft, timezone: timezone} = draft) do
    {slots, counter} =
      draft.time_slots
      |> Enum.sort_by(& &1.position)
      |> Enum.reduce({[], 0}, fn slot, {rows, counter} ->
        CandidateTimes.add(rows, counter, LocalTime.to_input(slot.start_time, timezone))
      end)

    [
      title: draft.title,
      description: draft.description || "",
      meeting_type_id:
        if(draft.meeting_type_id, do: Integer.to_string(draft.meeting_type_id), else: ""),
      duration: Integer.to_string(draft.duration_minutes),
      deadline: LocalTime.to_input(draft.deadline_at, timezone),
      notify_on_vote: draft.notify_on_vote,
      reminder_picker: PollReminders.new(PollSchema.reminders(draft)),
      invitees: draft |> PollSchema.draft_invitees() |> Enum.map_join("\n", &invitee_line/1),
      access: PollAccess.value(draft.invite_only),
      access_chosen?: true,
      timezone: timezone,
      slots: slots,
      slot_counter: counter
    ]
  end

  # One line per invitee, as `Tymeslot.Polls.Invitations.parse/1` reads it
  # back: a name holding a separator is quoted, as in an address book.
  defp invitee_line(%{email: email, name: name}) when name in [nil, ""], do: email

  defp invitee_line(%{email: email, name: name}) do
    if String.contains?(name, [",", ";"]),
      do: ~s("#{name}" <#{email}>),
      else: "#{name} <#{email}>"
  end
end
