defmodule Tymeslot.Meetings.Guests do
  @moduledoc """
  Domain logic for meeting guests.

  Owns the two business operations around guests:

    * sanitising the raw guest-email list submitted with a booking, and
    * recording a guest's RSVP from a tokenised link.

  Persistence is delegated to `Tymeslot.Meetings.GuestQueries`; this module
  holds the rules.

  A guest may only respond while their invitation is open: the meeting is a
  live, agreed booking (not cancelled or declined, expired, completed, unpaid
  or still awaiting the host's approval) and has not yet started. Recording a
  response notifies the organiser's dashboard over PubSub; subscribe with
  `subscribe_to_rsvp_updates/1`.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema
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
  Inserts the given sanitised guest emails for a meeting.

  Intended to be called inside the booking-creation transaction so that a
  failure rolls the whole booking back. Returns `{:ok, guests}` with the
  inserted rows, or `{:error, changeset}` on the first failure.
  """
  @spec create_for_meeting(binary(), [String.t()]) ::
          {:ok, [GuestSchema.t()]} | {:error, Ecto.Changeset.t()}
  def create_for_meeting(_meeting_id, []), do: {:ok, []}

  def create_for_meeting(meeting_id, emails) when is_binary(meeting_id) and is_list(emails) do
    result =
      Enum.reduce_while(emails, {:ok, []}, fn email, {:ok, acc} ->
        case GuestQueries.insert_guest(%{meeting_id: meeting_id, email: email}) do
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

      if rsvp_open?(guest.meeting), do: {:ok, guest}, else: {:error, :meeting_closed}
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

  # An invitation is open while the booking is live and agreed, and the
  # meeting has not started. `awaiting_approval` is live for the invitee but
  # the host has not agreed to it yet, so its guests have nothing to answer.
  defp rsvp_open?(meeting) do
    MeetingState.active?(meeting) and not MeetingState.awaiting_approval?(meeting) and
      DateTime.after?(meeting.start_time, Clock.utc_now())
  end

  defp broadcast_rsvp_update(%{organizer_user_id: user_id, id: meeting_id})
       when is_integer(user_id) do
    Phoenix.PubSub.broadcast(@pubsub, rsvp_topic(user_id), {:guest_rsvp_updated, meeting_id})
  end

  defp broadcast_rsvp_update(_meeting), do: :ok

  defp rsvp_topic(user_id), do: "guest_rsvps:#{user_id}"

  defp valid_email?(email), do: EmailValidator.validate(email) == :ok

  defp normalize(nil), do: ""
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""

  defp now, do: DateTime.utc_now(:second)
end
