defmodule Tymeslot.Meetings.Guests do
  @moduledoc """
  Domain logic for meeting guests.

  Owns the business operations around guests:

    * sanitising the raw guest-email list submitted with a booking,
    * the host inviting further guests once the booking exists, and
    * recording a guest's RSVP from a tokenised link.

  Persistence is delegated to `Tymeslot.Meetings.GuestQueries`; this module
  holds the rules.

  A guest may only respond while their invitation is open: the meeting is a
  live, agreed booking (not cancelled or declined, expired, completed, unpaid
  or still awaiting the host's approval), its time still holds (no reschedule
  is pending) and it has not yet started. Recording a
  response notifies the organiser's dashboard over PubSub; subscribe with
  `subscribe_to_rsvp_updates/1`.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo
  alias Tymeslot.Security.FieldValidators.EmailValidator

  @pubsub Tymeslot.PubSub

  @max_guests 10

  @typedoc "Aggregate RSVP counts for a meeting's guest list."
  @type summary :: GuestSchema.summary()

  @doc "The maximum number of guests allowed on a single booking."
  @spec max_guests() :: pos_integer()
  def max_guests, do: @max_guests

  @doc """
  Sanitises a raw list of guest emails submitted with a booking.

  Trims and downcases each entry, drops blanks and anything that fails email
  validation, removes the primary attendee's own address, de-duplicates, and
  caps the result at `max_guests/0`. Always returns a list — never raises.
  """
  @spec sanitize_emails([String.t()] | nil, String.t() | nil) :: [String.t()]
  def sanitize_emails(emails, primary_email) when is_list(emails) do
    primary = normalize(primary_email)

    emails
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == "" or &1 == primary))
    |> Enum.filter(&valid_email?/1)
    |> Enum.uniq()
    |> Enum.take(@max_guests)
  end

  def sanitize_emails(_emails, _primary_email), do: []

  @doc """
  Whether `email` is an address a guest can be invited at: the same rule
  `sanitize_emails/2` applies, so a form that checks an address with this
  never offers one the booking would then drop.
  """
  @spec valid_email?(term()) :: boolean()
  def valid_email?(email), do: EmailValidator.validate(email) == :ok

  @doc """
  Inserts the given sanitised guest emails for a meeting.

  `invited_by` records who is inviting them (`:booker` for the person booking
  on the public page, `:organizer` for the host), so their invitation names
  the right person.

  Intended to be called inside the booking-creation transaction so that a
  failure rolls the whole booking back. Returns `{:ok, guests}` with the
  inserted rows, or `{:error, changeset}` on the first failure.
  """
  @spec create_for_meeting(binary(), [String.t()], GuestSchema.inviter()) ::
          {:ok, [GuestSchema.t()]} | {:error, Ecto.Changeset.t()}
  def create_for_meeting(meeting_id, emails, invited_by \\ :booker)

  def create_for_meeting(_meeting_id, [], _invited_by), do: {:ok, []}

  def create_for_meeting(meeting_id, emails, invited_by)
      when is_binary(meeting_id) and is_list(emails) and invited_by in [:booker, :organizer] do
    result =
      Enum.reduce_while(emails, {:ok, []}, fn email, {:ok, acc} ->
        attrs = %{meeting_id: meeting_id, email: email, invited_by: invited_by}

        case GuestQueries.insert_guest(attrs) do
          {:ok, guest} -> {:cont, {:ok, [guest | acc]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)

    case result do
      {:ok, guests} -> {:ok, Enum.reverse(guests)}
      error -> error
    end
  end

  @doc """
  Invites guests to a meeting the host already has, after the booking was made.

  Scoped to the organiser: a meeting `organizer_user_id` does not own is
  `{:error, :not_found}`, exactly as one that does not exist. The meeting must
  still be open to guests (`invitations_open?/1`), or `{:error, :closed}`.

  This is the host's own path. The meeting type's `allow_guests` decides what
  the *booker* may do on the public form, and says nothing about whom the host
  may invite to their own meeting afterwards; `Bookings.CreateAdHoc` treats it
  the same way.

  Returns only the guests actually added. Addresses already on the meeting are
  dropped rather than refused, so inviting a list twice is harmless and never
  produces a second invitation. `{:error, :full}` comes back when the meeting
  is already at `max_guests/0`, counted across the guests it already has.

  The meeting row is locked for the duration, so two additions cannot both
  read the same count and overshoot the cap, and the invitation job is
  enqueued in the same transaction as the rows it sends to: either both exist
  or neither does.
  """
  @spec invite_for_organizer(binary(), integer(), [String.t()] | nil) ::
          {:ok, [GuestSchema.t()]}
          | {:error, :not_found | :closed | :full | Ecto.Changeset.t() | String.t()}
  def invite_for_organizer(meeting_id, organizer_user_id, emails)
      when is_integer(organizer_user_id) do
    Repo.transaction(fn ->
      with {:ok, meeting} <-
             MeetingQueries.lock_meeting_for_organizer(meeting_id, organizer_user_id),
           :ok <- ensure_open(meeting),
           {:ok, added} <- add_to_meeting(meeting, emails),
           :ok <- schedule_invitations(meeting, added) do
        added
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Whether a meeting takes new guests and their responses: the booking is live
  and agreed, its time still holds (no reschedule is pending), and it has not
  started. `awaiting_approval` is live for the invitee, but the host has not
  agreed to it yet, so a guest would have nothing to answer.
  """
  @spec invitations_open?(MeetingSchema.t()) :: boolean()
  def invitations_open?(meeting) do
    MeetingState.active?(meeting) and not MeetingState.awaiting_approval?(meeting) and
      not MeetingState.slot_void?(meeting) and
      DateTime.after?(meeting.start_time, Clock.utc_now())
  end

  defp ensure_open(meeting) do
    if invitations_open?(meeting), do: :ok, else: {:error, :closed}
  end

  defp add_to_meeting(meeting, emails) do
    existing = GuestQueries.list_for_meeting(meeting.id)
    known = MapSet.new(existing, &normalize(&1.email))
    room = @max_guests - length(existing)

    additions =
      emails
      |> sanitize_emails(meeting.attendee_email)
      |> Enum.reject(&MapSet.member?(known, &1))

    cond do
      additions == [] -> {:ok, []}
      room <= 0 -> {:error, :full}
      true -> create_for_meeting(meeting.id, Enum.take(additions, room), :organizer)
    end
  end

  defp schedule_invitations(_meeting, []), do: :ok

  defp schedule_invitations(meeting, added),
    do: MeetingScheduler.schedule_guest_invitations(meeting.id, Enum.map(added, & &1.id))

  @doc """
  Looks up the open invitation behind an RSVP token without mutating anything.

  Returns the guest with its `:meeting` preloaded. Returns
  `{:error, :not_found}` for an unknown token and `{:error, :meeting_closed}`
  when the meeting no longer takes responses (see the module doc).
  """
  @spec get_open_invitation(String.t()) ::
          {:ok, GuestSchema.t()} | {:error, :not_found | :meeting_closed}
  def get_open_invitation(token) do
    with {:ok, guest} <- GuestQueries.get_by_token(token) do
      guest = Repo.preload(guest, :meeting)

      if invitations_open?(guest.meeting), do: {:ok, guest}, else: {:error, :meeting_closed}
    end
  end

  @doc """
  Records a guest's RSVP from their token and notifies the organiser.

  `response` must be `"accepted"` or `"declined"`. Stamps `responded_at` with
  the current time and broadcasts `{:guest_rsvp_updated, meeting_id}` to the
  organiser's RSVP topic. Returns the updated guest with its `:meeting`
  preloaded, `{:error, :not_found}` for an unknown token,
  `{:error, :meeting_closed}` when the meeting no longer takes responses, and
  `{:error, :invalid_response}` for anything other than accept/decline.
  """
  @spec record_rsvp(String.t(), String.t()) ::
          {:ok, GuestSchema.t()}
          | {:error, :not_found | :meeting_closed | :invalid_response | Ecto.Changeset.t()}
  def record_rsvp(token, response) when response in ["accepted", "declined"] do
    with {:ok, guest} <- get_open_invitation(token),
         {:ok, updated} <-
           GuestQueries.update_rsvp(guest, %{status: response, responded_at: now()}) do
      broadcast_rsvp_update(updated.meeting)
      {:ok, updated}
    end
  end

  def record_rsvp(_token, _response), do: {:error, :invalid_response}

  @doc """
  Subscribes the calling process to RSVP updates on the meetings organised by
  `user_id`. Subscribers receive `{:guest_rsvp_updated, meeting_id}`.
  """
  @spec subscribe_to_rsvp_updates(integer()) :: :ok | {:error, term()}
  def subscribe_to_rsvp_updates(user_id) when is_integer(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, rsvp_topic(user_id))
  end

  @doc "Lists the guests attached to a meeting, oldest first."
  @spec list_for_meeting(binary()) :: [GuestSchema.t()]
  def list_for_meeting(meeting_id), do: GuestQueries.list_for_meeting(meeting_id)

  @doc "Aggregates RSVP counts for a list of guests."
  @spec summarize([GuestSchema.t()]) :: summary()
  def summarize(guests) when is_list(guests) do
    Enum.reduce(guests, GuestSchema.empty_summary(), fn %GuestSchema{status: status}, acc ->
      acc
      |> Map.update!(:total, &(&1 + 1))
      |> Map.update!(GuestSchema.status_key(status), &(&1 + 1))
    end)
  end

  defp broadcast_rsvp_update(%{organizer_user_id: user_id, id: meeting_id})
       when is_integer(user_id) do
    Phoenix.PubSub.broadcast(@pubsub, rsvp_topic(user_id), {:guest_rsvp_updated, meeting_id})
  end

  defp broadcast_rsvp_update(_meeting), do: :ok

  defp rsvp_topic(user_id), do: "guest_rsvps:#{user_id}"

  defp normalize(nil), do: ""
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""

  defp now, do: DateTime.utc_now(:second)
end
