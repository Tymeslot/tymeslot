defmodule Tymeslot.InviteeData.InviteeDataQueries do
  @moduledoc """
  Finds and scrubs the personal data invitees give a host, across every table
  that holds it: meetings, group seats, guests, poll participants, booking
  payments and the outgoing delivery logs.

  Pure data access. Which rows are scrubbed, and when, is decided by
  `Tymeslot.InviteeData`.

  Lookups take a `scope`: `:all`, or a host's user id to keep to that host's
  meetings and polls. Emails are compared case-insensitively against an
  already lower-cased `email`.

  A scrubbed row is kept, so that counts and statistics still add up. Columns
  that cannot be null and must stay unique per meeting or poll take a
  placeholder address built from the row's own id under the reserved
  `.invalid` domain, which also marks a poll participant as already scrubbed.
  """

  import Ecto.Query

  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.GuestSchema, as: Guest
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Polls.PollParticipantSchema, as: PollParticipant
  alias Tymeslot.Polls.PollSchema, as: Poll
  alias Tymeslot.Polls.PollTimeSlotSchema, as: PollTimeSlot
  alias Tymeslot.Repo
  alias Tymeslot.Slack.SlackDeliverySchema
  alias Tymeslot.Telegram.TelegramDeliverySchema
  alias Tymeslot.Webhooks.WebhookDeliverySchema

  @erased_suffix "@erased.invalid"

  # The title a booking is given names the invitee ("Intro call with Ada"), so
  # a scrubbed meeting falls back to its meeting type's name.
  @fallback_title "Meeting"

  @type scope :: :all | integer()
  @type rows :: {:ids, [binary()]} | {:meetings, [binary()]}

  # ---------------------------------------------------------------------------
  # Lookups by email
  # ---------------------------------------------------------------------------

  @doc """
  The uids of meetings still to take place that `email` is booked into, as
  the booker, a group seat or a guest.
  """
  @spec upcoming_meeting_uids(String.t(), scope(), DateTime.t()) :: [String.t()]
  def upcoming_meeting_uids(email, scope, %DateTime{} = now) do
    booked = from(m in Meeting, where: fragment("lower(?)", m.attendee_email) == ^email)

    seated =
      from(m in Meeting,
        join: p in Participant,
        on: p.meeting_id == m.id and is_nil(p.cancelled_at),
        where: fragment("lower(?)", p.email) == ^email
      )

    invited =
      from(m in Meeting,
        join: g in Guest,
        on: g.meeting_id == m.id,
        where: fragment("lower(?)", g.email) == ^email
      )

    [booked, seated, invited]
    |> Enum.flat_map(fn query ->
      query
      |> where([m], m.end_time > ^now)
      |> MeetingState.where_not_released()
      |> scope_meetings(scope)
      |> select([m], m.uid)
      |> Repo.all()
    end)
    |> Enum.uniq()
  end

  @doc "Ids of the meetings `email` booked as the attendee."
  @spec meeting_ids_for_attendee(String.t(), scope()) :: [binary()]
  def meeting_ids_for_attendee(email, scope) do
    from(m in Meeting, where: fragment("lower(?)", m.attendee_email) == ^email, select: m.id)
    |> scope_meetings(scope)
    |> Repo.all()
  end

  @doc "`{id, meeting_id}` of every group seat held under `email`."
  @spec participant_rows_for_email(String.t(), scope()) :: [{binary(), binary()}]
  def participant_rows_for_email(email, scope) do
    from(p in Participant,
      join: m in assoc(p, :meeting),
      as: :meeting,
      where: fragment("lower(?)", p.email) == ^email,
      select: {p.id, p.meeting_id}
    )
    |> scope_joined_meeting(scope)
    |> Repo.all()
  end

  @doc "`{id, meeting_id}` of every guest invitation sent to `email`."
  @spec guest_rows_for_email(String.t(), scope()) :: [{binary(), binary()}]
  def guest_rows_for_email(email, scope) do
    from(g in Guest,
      join: m in assoc(g, :meeting),
      as: :meeting,
      where: fragment("lower(?)", g.email) == ^email,
      select: {g.id, g.meeting_id}
    )
    |> scope_joined_meeting(scope)
    |> Repo.all()
  end

  @doc "Ids of the poll participants answering under `email`."
  @spec poll_participant_ids_for_email(String.t(), scope()) :: [binary()]
  def poll_participant_ids_for_email(email, scope) do
    from(pp in PollParticipant,
      join: p in Poll,
      as: :poll,
      on: p.id == pp.poll_id,
      where: fragment("lower(?)", pp.email) == ^email,
      select: pp.id
    )
    |> scope_joined_poll(scope)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Lookups by age
  # ---------------------------------------------------------------------------

  @doc """
  Up to `limit` ids of meetings that ended before `cutoff` and still hold
  invitee data.
  """
  @spec meeting_ids_ended_before(DateTime.t(), pos_integer()) :: [binary()]
  def meeting_ids_ended_before(%DateTime{} = cutoff, limit) do
    query =
      from(m in Meeting,
        where: m.end_time < ^cutoff and is_nil(m.invitee_data_erased_at),
        order_by: m.end_time,
        limit: ^limit,
        select: m.id
      )

    Repo.all(query)
  end

  @doc """
  Up to `limit` ids of not yet scrubbed participants of polls whose last
  proposed time ended before `cutoff`.
  """
  @spec poll_participant_ids_ended_before(DateTime.t(), pos_integer()) :: [binary()]
  def poll_participant_ids_ended_before(%DateTime{} = cutoff, limit) do
    ended_polls =
      from(s in PollTimeSlot,
        group_by: s.poll_id,
        having: max(s.end_time) < ^cutoff,
        select: s.poll_id
      )

    query =
      from(pp in PollParticipant,
        where: pp.poll_id in subquery(ended_polls),
        where: not like(pp.email, ^"%#{@erased_suffix}"),
        limit: ^limit,
        select: pp.id
      )

    Repo.all(query)
  end

  # ---------------------------------------------------------------------------
  # Scrubbing
  # ---------------------------------------------------------------------------

  @doc """
  Clears what the attendee gave on the meetings `ids`: their contact details,
  message and answers, the reasons exchanged on cancelling or declining, the
  notification snapshot that lists attendee addresses, and the tracking
  identifiers. The title, which names the attendee, becomes the meeting
  type's name, and a phone location, which carries their number, is cleared.

  Pass `erased_at:` to also mark the meeting as fully scrubbed for the
  retention purge.
  """
  @spec scrub_meetings([binary()], DateTime.t(), keyword()) :: {non_neg_integer(), nil}
  def scrub_meetings(ids, %DateTime{} = now, opts \\ []) do
    erased_at = Keyword.get(opts, :erased_at)

    query =
      from(m in Meeting,
        where: m.id in ^ids,
        update: [
          set: [
            title: fragment("coalesce(?, ?)", m.meeting_type, ^@fallback_title),
            summary: fragment("coalesce(?, ?)", m.meeting_type, ^@fallback_title),
            location: fragment("CASE WHEN ? IS NULL THEN ? END", m.attendee_phone, m.location),
            attendee_name: nil,
            attendee_email: nil,
            attendee_phone: nil,
            attendee_company: nil,
            attendee_message: nil,
            cancellation_reason: nil,
            decline_reason: nil,
            custom_field_answers: ^%{},
            last_notified_state: ^%{},
            tracking_params: ^%{},
            visitor_hash: nil,
            invitee_data_erased_at:
              fragment("coalesce(?, ?)", m.invitee_data_erased_at, ^erased_at),
            updated_at: ^now
          ]
        ]
      )

    Repo.update_all(query, [])
  end

  @doc "Clears the group seats selected by `rows`, keeping each seat."
  @spec scrub_participants(rows(), DateTime.t()) :: {non_neg_integer(), nil}
  def scrub_participants(rows, %DateTime{} = now) do
    from(p in Participant,
      update: [
        set: [
          name: "",
          email: fragment("'erased-' || ?::text || ?", p.id, ^@erased_suffix),
          phone: nil,
          company: nil,
          message: nil,
          custom_field_answers: ^%{},
          management_token: nil,
          management_token_hash: nil,
          updated_at: ^now
        ]
      ]
    )
    |> select_rows(rows)
    |> Repo.update_all([])
  end

  @doc "Clears the guest invitations selected by `rows`, keeping each one."
  @spec scrub_guests(rows(), DateTime.t()) :: {non_neg_integer(), nil}
  def scrub_guests(rows, %DateTime{} = now) do
    from(g in Guest,
      update: [
        set: [
          name: nil,
          email: fragment("'erased-' || ?::text || ?", g.id, ^@erased_suffix),
          rsvp_token: nil,
          rsvp_token_hash: nil,
          updated_at: ^now
        ]
      ]
    )
    |> select_rows(rows)
    |> Repo.update_all([])
  end

  @doc "Clears the poll participants `ids`, keeping their votes."
  @spec scrub_poll_participants([binary()], DateTime.t()) :: {non_neg_integer(), nil}
  def scrub_poll_participants(ids, %DateTime{} = now) do
    query =
      from(pp in PollParticipant,
        where: pp.id in ^ids,
        update: [
          set: [
            name: "",
            email: fragment("'erased-' || ?::text || ?", pp.id, ^@erased_suffix),
            token: nil,
            token_hash: nil,
            updated_at: ^now
          ]
        ]
      )

    Repo.update_all(query, [])
  end

  @doc """
  Clears the attendee's name and email on booking payments, selected by the
  meetings they paid for or by `email` within `scope`. The payment itself is
  kept for its statutory period (`Tymeslot.MeetingPayments.DataRetention`).
  """
  @spec scrub_booking_payments(
          {:meetings, [binary()]} | {:email, String.t(), scope()},
          DateTime.t()
        ) ::
          {non_neg_integer(), nil}
  def scrub_booking_payments(selection, %DateTime{} = now) do
    BookingPaymentSchema
    |> select_payments(selection)
    |> Repo.update_all(set: [attendee_email: nil, attendee_name: nil, updated_at: now])
  end

  @doc """
  Deletes the webhook, Slack and Telegram delivery logs of `meeting_ids`,
  whose payloads repeat the booking's details.
  """
  @spec delete_deliveries([binary()]) :: non_neg_integer()
  def delete_deliveries([]), do: 0

  def delete_deliveries(meeting_ids) do
    {webhooks, _rows} =
      Repo.delete_all(from(d in WebhookDeliverySchema, where: d.meeting_id in ^meeting_ids))

    {slack, _rows} =
      Repo.delete_all(from(d in SlackDeliverySchema, where: d.meeting_id in ^meeting_ids))

    {telegram, _rows} =
      Repo.delete_all(from(d in TelegramDeliverySchema, where: d.meeting_id in ^meeting_ids))

    webhooks + slack + telegram
  end

  defp select_rows(query, {:ids, ids}), do: where(query, [r], r.id in ^ids)
  defp select_rows(query, {:meetings, ids}), do: where(query, [r], r.meeting_id in ^ids)

  defp select_payments(query, {:meetings, ids}), do: where(query, [b], b.meeting_id in ^ids)

  defp select_payments(query, {:email, email, :all}),
    do: where(query, [b], fragment("lower(?)", b.attendee_email) == ^email)

  defp select_payments(query, {:email, email, host_user_id}) when is_integer(host_user_id) do
    query
    |> select_payments({:email, email, :all})
    |> where([b], b.host_user_id == ^host_user_id)
  end

  defp scope_meetings(query, :all), do: query

  defp scope_meetings(query, host_user_id) when is_integer(host_user_id),
    do: where(query, [m], m.organizer_user_id == ^host_user_id)

  defp scope_joined_meeting(query, :all), do: query

  defp scope_joined_meeting(query, host_user_id) when is_integer(host_user_id),
    do: where(query, [meeting: m], m.organizer_user_id == ^host_user_id)

  defp scope_joined_poll(query, :all), do: query

  defp scope_joined_poll(query, host_user_id) when is_integer(host_user_id),
    do: where(query, [poll: p], p.user_id == ^host_user_id)
end
