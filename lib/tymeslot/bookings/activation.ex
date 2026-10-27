defmodule Tymeslot.Bookings.Activation do
  @moduledoc """
  Turning a confirmed meeting into a booking the world knows about.

  Two paths arrive at the same point. A booking on an ordinary meeting type is
  confirmed the moment it is created; a booking on a meeting type requiring
  manual approval is confirmed later, when the host says yes. From that point
  on the work is identical: create the video room if the meeting has a
  provider, then send the confirmation emails and fan out to webhooks,
  Telegram and Slack.

  It lives in its own module so the two paths cannot drift. The ordering
  matters and is easy to get wrong from a second call site: the video room is
  created *before* the emails so the join link is in the confirmation the
  attendee receives, rather than arriving in a later correction. Where a
  provider is configured, that means handing both steps to
  `Tymeslot.Workers.VideoRoomWorker`, which sends the emails itself once the
  room exists — and falls back to sending them without a link if the provider
  is unreachable, so a broken video integration never costs the attendee their
  confirmation.

  Every path takes the work in two halves: the room job, emails and reminders
  in the transaction that creates or confirms the booking
  (`activate_in_transaction/2`), and the webhook, Telegram and Slack fan-out
  after it commits (`after_commit/1`). That is `Tymeslot.Bookings.Create` and
  `Tymeslot.Bookings.CreateAdHoc` creating a booking, `Tymeslot.Meetings.Approval`
  confirming a held one, and the paid checkout confirming a paid one. The
  booking and its emails commit together or not at all: a booking nobody was
  told about, with its announcement claimed so that nothing would ever tell
  them, is the failure this rules out.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Workers.VideoRoomWorker

  # Providers whose rooms Tymeslot creates through an API call, and which
  # therefore need the video job to run before the confirmation email is
  # composed. This is every provider `Video` knows about except `:none` (no
  # integration configured, so there is nothing to create), derived at
  # compile time from `ProviderConfig.known_providers/0` rather than
  # `ProviderConfig.all_providers/0`, because the latter is toggle-filtered:
  # an integration a host already connected before its provider was disabled
  # must still get its room created, not silently skip straight to
  # `notify/1`. Deriving it, instead of restating the provider list by hand,
  # is what keeps a newly registered provider from being missed here the way
  # kMeet and Jitsi once were; the assertion below is a second line of
  # defence against `known_providers/0` ever growing the `:none` sentinel
  # into this list.
  @api_created_providers VideoProviderConfig.known_providers()

  if :none in @api_created_providers do
    raise "ProviderConfig.known_providers/0 must never include :none: it is the " <>
            "sentinel for \"no video integration\", not a provider whose room " <>
            "Activation should hand to VideoRoomWorker"
  end

  @doc """
  Runs the side effects a newly created or newly confirmed meeting needs, in
  the transaction that created or confirmed it.

  A meeting still awaiting the host's approval takes the request fan-out; any
  other status takes the confirmation one.

  With `with_video_room: true` the caller asserts the booking flow wants a
  room whenever the meeting has an integration; without it, the provider is
  auto-detected and only the API-backed ones defer the emails.

  This half runs in the transaction: the video room job, the emails and the
  reminders, all of them jobs written with the meeting, so a booking that
  loses its slot and rolls back leaves none of them behind. It returns
  `{:ok, pending}`, the integration fan-out (webhooks, Telegram, Slack) still
  owed, which the caller hands to `after_commit/1` once the transaction has
  committed, and drops if it rolls back. The fan-out stays out of the
  transaction because a database error inside one of those best-effort
  dispatchers, even rescued, would leave the transaction unable to commit
  and lose the booking.

  `{:error, reason}` means an email or reminder could not be enqueued. The
  caller must roll its transaction back: the booking, its announcement claim
  and any job already written go with it, and the person booking (or the
  host approving, or Stripe redelivering a payment) retries the whole thing.
  """
  @spec activate_in_transaction(Meeting.t(), keyword()) ::
          {:ok, Events.pending()} | {:error, term()}
  def activate_in_transaction(meeting, opts \\ [])

  # A booking still held for the host to approve is not a booking anyone has
  # agreed to, so none of the confirmation work runs. Branching here rather
  # than at each call site means no future caller can accidentally send a
  # confirmation for a meeting the host has not accepted;
  # `Tymeslot.Meetings.Approval` calls back in once it has confirmed.
  #
  # The request still has to reach people — the invitee needs telling their
  # booking is not final, and the host cannot approve what they never heard
  # about — so it takes the request fan-out instead.
  def activate_in_transaction(%Meeting{status: "awaiting_approval"} = meeting, _opts) do
    meeting
    |> Events.meeting_requested_deferred()
    |> settle(meeting, "Failed to schedule booking request emails")
  end

  def activate_in_transaction(%Meeting{} = meeting, opts) do
    if wants_video_room?(meeting, opts) do
      schedule_video_room_with_announcement(meeting)
    else
      notify(meeting)
    end
  end

  @doc """
  The second half of `activate_in_transaction/2`: the integration fan-out it
  returned, run once the booking has committed. Always returns `:ok`; a
  failing channel is logged and reported, and the booking stands.

  Raises when called inside a transaction (see
  `Tymeslot.Notifications.Events.dispatch_deferred/1`). A caller that opens
  one around a booking path (as `Tymeslot.Polls.Confirm` does around
  `Tymeslot.Bookings.CreateAdHoc`) has to take the pending fan-out back and
  run it after its own commit.
  """
  @spec after_commit(Events.pending()) :: :ok
  def after_commit(pending), do: Events.dispatch_deferred(pending)

  @doc """
  True when the meeting's video provider creates its room through an API, so
  the confirmation emails are worth holding until the join link exists.

  Public because the group-booking path
  (`Tymeslot.Bookings.SeatEffects`) faces the same question for the first
  seat on a slot, and must not answer it from a second copy of
  `@api_created_providers`.
  """
  @spec api_created_video_room?(Meeting.t()) :: boolean()
  def api_created_video_room?(%Meeting{} = meeting) do
    match?({:ok, provider} when provider in @api_created_providers, video_provider_for(meeting))
  end

  defp wants_video_room?(meeting, opts) do
    if Keyword.get(opts, :with_video_room, false) do
      not is_nil(meeting.video_integration_id)
    else
      api_created_video_room?(meeting)
    end
  end

  # The room job announces the booking itself once it runs, after commit, so
  # nothing is owed from here.
  defp schedule_video_room_with_announcement(meeting) do
    case VideoRoomWorker.schedule_video_room_creation_with_announcement(meeting.id) do
      :ok -> {:ok, []}
      {:error, _reason} -> notify(meeting)
    end
  end

  defp notify(meeting) do
    meeting
    |> Events.meeting_created_deferred()
    |> settle(meeting, "Failed to schedule confirmation emails for meeting")
  end

  defp settle({{:error, reason}, _pending}, meeting, message) do
    Logger.error(message, meeting_id: meeting.id, error: LogFormat.reason(reason))
    {:error, reason}
  end

  defp settle({_result, pending}, _meeting, _message), do: {:ok, pending}

  defp video_provider_for(%Meeting{video_integration_id: nil}), do: {:error, :not_found}

  defp video_provider_for(%Meeting{} = meeting) do
    with {:ok, integration} <-
           Video.fetch_integration_for_user(
             meeting.video_integration_id,
             meeting.organizer_user_id
           ) do
      {:ok, parse_provider(integration, meeting)}
    end
  end

  defp parse_provider(integration, meeting) do
    case VideoProviderConfig.parse_known(integration.provider) do
      {:ok, provider} ->
        provider

      {:error, :unknown} ->
        Logger.warning("Video integration has an unrecognised provider",
          video_integration_id: meeting.video_integration_id,
          provider: integration.provider
        )

        :none
    end
  end
end
