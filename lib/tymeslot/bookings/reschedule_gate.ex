defmodule Tymeslot.Bookings.RescheduleGate do
  @moduledoc """
  Where a reschedule leaves a booking against its meeting type's approval
  gate: the status and approval fields `Tymeslot.Bookings.Reschedule` writes
  with the new time. The rule itself, and why it applies only to confirmed
  and held bookings, is in `Tymeslot.Bookings.Reschedule`'s module doc.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.Approval

  # On an ungated meeting type, or on a gated one whose current status the
  # gate is not meaningful for (see `Tymeslot.Bookings.Reschedule`'s module
  # doc), `status` is left untouched: it tracks the booking lifecycle
  # (pending, awaiting_payment, confirmed, ...), which a reschedule never
  # changes there.
  #
  # On a gated one being moved from `:confirmed` or `:awaiting_approval`,
  # the reschedule *is* a new request, so the whole approval record is reset
  # rather than partially updated: a stale `approval_resolved_at` would make
  # the new request look answered, a stale `approval_nudge_sent_at` would
  # suppress the nudge for a window that has not been nudged, and a stale
  # `announced_at` would leave `Events.meeting_created/1`'s once-per-meeting
  # claim (`Tymeslot.Meetings.MeetingDeliveryQueries.claim_announcement/1`) already spent — the host's
  # second approval would then win the DB transition but lose the fan-out,
  # so the invitee gets no reminders for the new time and the integration
  # channels never hear that it moved. Clearing it costs nothing that is
  # needed later: `first_announced_at` keeps the permanent record that this
  # booking was once a live meeting, which is what `Approval` reads when it
  # decides whether releasing the request refunds it, and what the claim reads
  # to announce the approval to webhooks, Telegram and Slack as
  # `meeting.rescheduled` rather than a second `meeting.created`. The
  # deadline is computed from now and capped at the new start time, exactly
  # as an original booking's is.
  #
  # A meeting type can also stop requiring approval while one of its bookings
  # is still held. Moving that booking must not leave it stranded in the
  # gate with a deadline computed against its old start time: nothing recaps
  # it, and `Approval.approve/1` refuses a meeting whose slot has passed, so
  # it would sit held until the expiry sweep with no way to be approved.
  # There is no gate left to hold it in, so the reschedule confirms it
  # outright instead, exactly as a fresh booking against the now-ungated type
  # would be.
  @doc """
  The status and approval attributes a booking moved to `start_time` is
  written with, given `meeting_type`, the type the move was validated
  against (`nil` for none). An empty map leaves the status as it is.
  """
  @spec attributes(map() | nil, DateTime.t(), map()) :: map()
  def attributes(meeting_type, start_time, meeting) do
    gate_type = gate_meeting_type(meeting_type, meeting)

    cond do
      Approval.required?(gate_type) and reenters_gate?(meeting) ->
        requested_at = DateTime.truncate(Clock.utc_now(), :second)

        %{
          status: :awaiting_approval,
          approval_requested_at: requested_at,
          approval_deadline_at: Approval.deadline_for(gate_type, requested_at, start_time),
          approval_resolved_at: nil,
          approval_declined_at: nil,
          approval_nudge_sent_at: nil,
          decline_reason: nil,
          announced_at: nil
        }

      not Approval.required?(gate_type) and meeting.status == :awaiting_approval ->
        %{status: :confirmed, approval_resolved_at: DateTime.truncate(Clock.utc_now(), :second)}

      true ->
        %{}
    end
  end

  # An ad-hoc booking — dragged onto the dashboard calendar, or produced by
  # confirming a poll — carries no `meeting_type_id`, and `Approval.required?/1`
  # already states the rule for it: no meeting type means no gate. Creation
  # honours that (`Bookings.Policy` resolves the type by id and gets `nil`), so
  # a reschedule must too.
  #
  # It does not fall out of `Reschedule`'s `fetch_meeting_type/3`, which answers a different
  # question: with no id to look up, it matches a type by duration slug so that
  # the reschedule enforces the same *schedule* the grid the invitee saw was
  # drawn from. Every account is seeded with types named "15 Minutes" and
  # "30 Minutes", whose slugs are exactly what that lookup builds, so a
  # 30-minute ad-hoc booking reliably resolves the host's stock 30-minute type.
  # Reading `requires_approval` off it would send a booking made under no
  # meeting type into a gate on the strength of a setting the host ticked
  # somewhere else entirely, where it could then sit unanswered and be expired
  # by the sweep.
  defp gate_meeting_type(_meeting_type, %{meeting_type_id: nil}), do: nil
  defp gate_meeting_type(meeting_type, _meeting), do: meeting_type

  # Only these two statuses mean the invitee is expecting a decision from the
  # host: `:confirmed` (the host already agreed, and the reschedule asks
  # again) or `:awaiting_approval` (a held request being moved before anyone
  # has answered). `:awaiting_payment` never reached the host in the first
  # place, and `:expired` already lapsed and was refunded by
  # `Meetings.Approval` — reviving either into the gate would let the host
  # approve a booking nobody paid for, or one the invitee was already given
  # their money back for.
  defp reenters_gate?(%{status: status}), do: status in [:confirmed, :awaiting_approval]
end
