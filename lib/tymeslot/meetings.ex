defmodule Tymeslot.Meetings do
  @moduledoc """
  Business logic for managing meetings and appointments.
  Handles the complete meeting creation workflow including database persistence,
  calendar integration, and email notifications.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  require Logger

  alias Tymeslot.Bookings.{Cancel, CancelSeat, Reschedule, RescheduleRequest}
  alias Tymeslot.Infrastructure.Logging.LogFormat

  alias Tymeslot.Meetings.{
    BusyPeriods,
    CalendarEventLink,
    CalendarEvents,
    CalendarExport,
    CalendarMove,
    Cancellation,
    ExternalCalendarChanges,
    Guests,
    GuestSchema,
    Listing,
    MeetingAccess,
    MeetingAnalyticsQueries,
    MeetingCalendarQueries,
    MeetingListQueries,
    MeetingQueries,
    MeetingSchema,
    ParticipantSchema,
    Recipient,
    SeatLookup,
    VideoRoomAttachment,
    VideoRooms
  }

  alias Tymeslot.Pagination.CursorPage
  alias Tymeslot.Security.EncryptedString

  @owner_fixable_video_refusals [:video_integration_needs_reauth, :video_integration_inactive]

  # The guests' RSVP tokens and the group participants' seat tokens.
  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage do
    for schema <- [GuestSchema, ParticipantSchema],
        do: {schema.__schema__(:source), EncryptedString.columns(schema)}
  end

  @doc """
  Looks up the open invitation behind a guest's RSVP token, with its meeting
  and inviting participant preloaded. Returns `{:error, :meeting_closed}`
  once the meeting no longer takes responses.
  """
  defdelegate get_guest_invitation(token), to: Guests, as: :get_open_invitation

  @doc """
  Records a guest's RSVP (`"accepted"` / `"declined"`) from their token and
  notifies the organiser's dashboard.
  """
  defdelegate record_guest_rsvp(token, response), to: Guests, as: :record_rsvp

  @doc """
  Whether a guest can answer yes now: not a guest of a group booking who
  declined while no seat is free.
  """
  defdelegate guest_can_accept?(guest), to: Guests, as: :can_accept?

  @doc "Subscribes the caller to guest RSVP updates on a user's meetings."
  defdelegate subscribe_to_guest_rsvp_updates(user_id),
    to: Guests,
    as: :subscribe_to_rsvp_updates

  @doc "Aggregates RSVP counts for a list of guests."
  defdelegate guest_rsvp_summary(guests), to: Guests, as: :summarize

  @doc "Returns a `meeting_uid => RSVP summary` map for a user's guest meetings."
  defdelegate guest_rsvp_summaries_for_user(user_id),
    to: Tymeslot.Meetings.GuestQueries,
    as: :rsvp_summaries_for_user

  @doc """
  The calendar identities (`calendar_uid`s) of the organiser's group meetings
  with live seats overlapping the UTC window `[from_utc, to_utc)`.
  """
  defdelegate group_booking_uids_for_user(user_id, from_utc, to_utc),
    to: Tymeslot.Meetings.GroupMeetingQueries

  @doc """
  Whether the organiser's meeting behind a calendar event's `uid` is a group
  meeting with live seats.
  """
  defdelegate group_booking_uid?(user_id, uid), to: Tymeslot.Meetings.GroupMeetingQueries

  @doc "Whether `meeting` was booked with room for more than one seat."
  defdelegate group?(meeting), to: MeetingSchema

  @doc "The video link the organiser joins `meeting` with, or `nil` without video."
  defdelegate organizer_join_url(meeting), to: MeetingSchema

  @doc """
  `meeting` (or each of a list of meetings) with its live participants
  loaded into `:participants`, oldest booking first: the people a group
  meeting is with.
  """
  @spec with_live_participants(MeetingSchema.t()) :: MeetingSchema.t()
  @spec with_live_participants([MeetingSchema.t()]) :: [MeetingSchema.t()]
  defdelegate with_live_participants(meeting),
    to: MeetingListQueries,
    as: :preload_live_participants

  @doc """
  Sets `capacity` on a meeting type's future, live group meetings so they
  follow the type's new seat limit. Solo meetings are left alone. Returns the
  number of meetings updated.
  """
  defdelegate set_future_group_capacity(meeting_type_id, capacity, now),
    to: Tymeslot.Meetings.GroupMeetingQueries

  @doc "Tells open booking pages that a meeting type's seat availability changed."
  defdelegate broadcast_seat_change(meeting_type_id), to: Tymeslot.Meetings.SeatBroadcast

  @doc """
  Cancels a meeting including all side effects.

  Delegates to Bookings.Cancel module.
  """
  @spec cancel_meeting(MeetingSchema.t()) ::
          {:ok, MeetingSchema.t()} | {:error, term()}
  def cancel_meeting(%MeetingSchema{} = meeting) do
    Cancel.execute(meeting)
  end

  @doc """
  Returns everyone on the meeting who should receive attendee-facing
  notifications: the attendee for solo meetings, one entry per live
  participant for group meetings. See `Tymeslot.Meetings.Recipient`.
  """
  @spec recipients(MeetingSchema.t()) :: [Recipient.t()]
  defdelegate recipients(meeting), to: Recipient, as: :for_meeting

  @doc """
  The attendees to list on a synced calendar event.

  Solo meetings return `[]`: the event already carries its one attendee via
  the meeting's own `attendee_*` fields. Group meetings, whose `attendee_*`
  columns are always empty, return `recipients/1`: one entry per live
  participant.
  """
  @spec attendees_for_calendar(MeetingSchema.t()) :: [Recipient.t()]
  def attendees_for_calendar(meeting) do
    if group?(meeting), do: recipients(meeting), else: []
  end

  @doc """
  Returns the meeting as the given recipient sees it, with `attendee_*`
  fields and management URLs overlaid for participant recipients.
  """
  @spec meeting_as_seen_by(MeetingSchema.t(), Recipient.t()) :: MeetingSchema.t()
  defdelegate meeting_as_seen_by(meeting, recipient), to: Recipient, as: :as_seen_by

  @doc "Looks up a group-booking participant by their management token."
  @spec get_participant_by_token(String.t()) ::
          {:ok, Tymeslot.Meetings.ParticipantSchema.t()} | {:error, :not_found}
  defdelegate get_participant_by_token(token),
    to: Tymeslot.Meetings.ParticipantQueries,
    as: :get_by_token

  @doc """
  Cancels a participant's seat from their management token.

  Delegates to Bookings.CancelSeat; the last leaver cancels the whole
  meeting.
  """
  @spec cancel_seat(String.t()) ::
          {:ok, :seat_cancelled | :meeting_cancelled} | {:error, term()}
  def cancel_seat(management_token), do: CancelSeat.execute(management_token)

  @doc "Loads a live group-booking seat by its management token. See `Tymeslot.Meetings.SeatLookup`."
  @spec fetch_live_seat(String.t()) ::
          {:ok, SeatLookup.seat()} | {:error, SeatLookup.dead_end()}
  defdelegate fetch_live_seat(token), to: SeatLookup

  @doc "The organiser a seat's meeting belongs to, live or not. See `Tymeslot.Meetings.SeatLookup`."
  @spec seat_organizer_user_id(String.t()) :: {:ok, integer()} | {:error, :not_found}
  defdelegate seat_organizer_user_id(token), to: SeatLookup, as: :organizer_user_id

  @doc """
  Loads a live seat its participant may still cancel, refusing what
  `cancel_seat/1` would. See `Tymeslot.Meetings.SeatLookup`.
  """
  @spec fetch_cancellable_seat(String.t()) ::
          {:ok, SeatLookup.seat()} | {:error, SeatLookup.dead_end() | SeatLookup.refusal()}
  defdelegate fetch_cancellable_seat(token), to: SeatLookup

  @doc """
  Works out which refund a host's cancellation choice implies.

  See `Tymeslot.Meetings.Cancellation` for the rule.
  """
  @spec resolve_cancellation_refund(map() | nil, map()) ::
          {:ok, Cancellation.refund_action()} | {:error, Cancellation.refund_error()}
  defdelegate resolve_cancellation_refund(payment, params),
    to: Cancellation,
    as: :resolve_refund

  @doc """
  Cancels a meeting and issues the resolved refund to the attendee.

  Only the meeting's organiser (`acting_user_id` must be its
  `organizer_user_id`) may cancel through here, and a refund additionally
  needs the payment to be theirs; anyone else gets `{:error, :not_found}`
  before the meeting is touched.

  Returns `{:error, {:refund_failed, reason}}` when the meeting was cancelled
  but the refund could not be issued, so callers can tell the host to settle it
  manually rather than reporting a failed cancellation.
  """
  @spec cancel_meeting_with_refund(
          Ecto.Schema.t(),
          integer(),
          Cancellation.refund_action()
        ) :: {:ok, Ecto.Schema.t()} | {:error, term()}
  defdelegate cancel_meeting_with_refund(meeting, acting_user_id, refund_action),
    to: Cancellation,
    as: :cancel

  @doc """
  Reschedules an existing meeting.

  Delegates to Bookings.Reschedule module.

  The `organizer_user_id` is required. The meeting lookup is scoped to that
  owner, preventing IDOR attacks from the public booking flow.
  """
  @spec reschedule_meeting(String.t(), Reschedule.reschedule_params(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  def reschedule_meeting(meeting_uid, new_params, organizer_user_id) do
    Reschedule.execute(meeting_uid, new_params, organizer_user_id)
  end

  @doc """
  Cancels the calendar event associated with a meeting asynchronously.

  Schedules calendar event deletion through an Oban worker. Does not fail the
  broader cancellation workflow if scheduling fails.
  """
  defdelegate cancel_calendar_event(meeting), to: CalendarEvents

  # =====================================
  # Video Room Integration Functions
  # =====================================

  @doc """
  Adds a secure video room to an existing meeting.

  This is a high-level operation that ensures the meeting exists and the video
  room is successfully attached. It handles logging and error translation
  for the web layer.
  """
  @spec add_video_room_to_meeting(String.t()) :: {:ok, MeetingSchema.t()} | {:error, term()}
  def add_video_room_to_meeting(meeting_id) do
    Logger.info("Request to add video room to meeting", meeting_id: meeting_id)

    case VideoRooms.add_video_room_to_meeting(meeting_id) do
      {:ok, meeting} ->
        Logger.info("Successfully added video room", meeting_id: meeting_id)
        {:ok, meeting}

      {:error, :meeting_not_found} ->
        Logger.warning("Attempted to add video room to non-existent meeting",
          meeting_id: meeting_id
        )

        {:error, :meeting_not_found}

      # A Teams meeting waiting for the booking's own calendar event: the
      # expected first outcome, which `VideoRooms` already logs as a wait.
      {:error, :calendar_event_pending} = pending ->
        pending

      # A video integration switched off or waiting to be reconnected is the
      # owner's to fix, and the meeting goes ahead without a room: expected,
      # not a fault.
      {:error, reason} = error when reason in @owner_fixable_video_refusals ->
        Logger.info("Video room not added: the video integration is unavailable",
          meeting_id: meeting_id,
          reason: reason
        )

        error

      # `Tymeslot.Workers.VideoRoomWorker` logs a failure once, with what it
      # does about it.
      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Lets go of a video room the provider no longer has, and refreshes the
  calendar event of a booking still to come so it stops carrying the dead
  join link. See `Tymeslot.Meetings.VideoRoomAttachment.forget/2`.
  """
  @spec forget_video_room(MeetingSchema.t()) :: :ok
  defdelegate forget_video_room(meeting), to: VideoRoomAttachment, as: :forget

  @doc """
  Clears a video room off `meeting`, writing nothing else, for a caller that
  pairs the write with another in one transaction.
  """
  @spec clear_video_room(MeetingSchema.t()) ::
          {:ok, MeetingSchema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate clear_video_room(meeting), to: VideoRoomAttachment, as: :clear

  # =====================================
  # Meeting List and Query Functions
  # =====================================

  @doc """
  Lists the organiser's upcoming live bookings, soonest first, up to `limit`.
  """
  @spec list_upcoming_meetings_for_organizer(pos_integer(), integer()) :: [MeetingSchema.t()]
  defdelegate list_upcoming_meetings_for_organizer(organizer_user_id, limit),
    to: MeetingListQueries,
    as: :upcoming_meetings_for_organizer

  @doc """
  Lists every upcoming meeting the organiser holds, whatever its status.
  """
  @spec list_upcoming_meetings_for_organizer(pos_integer()) :: [MeetingSchema.t()]
  defdelegate list_upcoming_meetings_for_organizer(organizer_user_id), to: MeetingListQueries

  @doc """
  Lists the organiser's live bookings overlapping the `[from, to)` window,
  ordered by start time. Includes past bookings inside the window; excludes
  cancelled bookings and slots voided by a pending reschedule request.
  """
  @spec list_meetings_in_range_for_organizer(pos_integer(), DateTime.t(), DateTime.t()) ::
          [MeetingSchema.t()]
  defdelegate list_meetings_in_range_for_organizer(organizer_user_id, from, to),
    to: MeetingListQueries,
    as: :list_for_organizer_in_range

  @doc "Every meeting id `user_id` organises, past and future."
  @spec list_meeting_ids_for_organizer(pos_integer()) :: [Ecto.UUID.t()]
  defdelegate list_meeting_ids_for_organizer(user_id),
    to: MeetingListQueries,
    as: :list_ids_for_organizer

  @doc """
  How many booking requests this organiser has not yet answered; drives the
  dashboard's Requests tab badge.
  """
  @spec count_awaiting_approval_for_organizer(integer()) :: non_neg_integer()
  defdelegate count_awaiting_approval_for_organizer(organizer_user_id), to: MeetingQueries

  @doc """
  Sends a reschedule request email for a meeting.

  Validates the request against policy and manages the workflow state.
  """
  @spec send_reschedule_request(MeetingSchema.t()) :: :ok | {:error, term()}
  def send_reschedule_request(meeting) do
    case RescheduleRequest.send_reschedule_request(meeting) do
      :ok ->
        Logger.info("Reschedule request processed", meeting_id: meeting.id)
        :ok

      {:error, :already_requested} ->
        Logger.info("Reschedule already requested", meeting_id: meeting.id)
        :ok

      {:error, reason} = error ->
        Logger.warning("Reschedule request failed",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end

  @doc """
  The organiser's meeting with `meeting_id`, as a one-item page of dashboard
  cards (empty when they own no meeting by that id): the dashboard view a
  meeting's organiser links lead to
  (`Tymeslot.Bookings.MeetingLinks.host_view_url/1`).
  """
  @spec list_user_meeting(integer(), term()) :: {:ok, CursorPage.t()}
  defdelegate list_user_meeting(user_id, meeting_id), to: Listing

  @doc """
  High-level function to list meetings for a user based on a filter string.
  """
  @spec list_user_meetings_by_filter(integer(), String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_by_filter(user_id, filter, opts \\ []) do
    Listing.list_user_meetings_by_filter(user_id, filter, opts)
  end

  @doc """
  Gets a single meeting by ID.
  """
  @spec get_meeting(String.t() | integer()) :: {:ok, MeetingSchema.t()} | {:error, :not_found}
  defdelegate get_meeting(id), to: MeetingAccess

  @doc """
  Fetches a meeting by ID only if the given `organizer_user_id` owns it.

  The dashboard's lookup for every action that accepts a meeting id from the
  client. It never matches on an email address: an attendee holding an account
  under the booking email, or whoever later verifies an address the organiser
  gave up, must not be able to open or act on the meeting.
  """
  @spec get_meeting_for_organizer(String.t(), integer()) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def get_meeting_for_organizer(id, organizer_user_id) do
    MeetingQueries.get_meeting_for_organizer(id, organizer_user_id)
  end

  @doc """
  Fetches a meeting by UID only if the given `organizer_user_id` owns it.

  Returns `{:ok, meeting}` when a matching meeting is found.
  Returns `{:error, :not_found}` when no meeting exists with that UID, or when
  the meeting exists but belongs to a different organizer.

  Use this instead of `Tymeslot.Meetings.MeetingQueries.get_meeting_by_uid/1` on
  any user-facing route that accepts a meeting UID from the URL, to prevent
  IDOR attacks.
  """
  @spec get_meeting_by_uid_for_organizer(String.t(), integer()) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  defdelegate get_meeting_by_uid_for_organizer(uid, organizer_user_id), to: MeetingAccess

  @doc "Exports a solo meeting's `.ics` file. See `Tymeslot.Meetings.CalendarExport.meeting/2`."
  @spec calendar_export(String.t(), integer()) :: {:ok, String.t()} | {:error, :not_found}
  defdelegate calendar_export(uid, organizer_user_id), to: CalendarExport, as: :meeting

  @doc "Exports a group-booking seat's own `.ics` file. See `Tymeslot.Meetings.CalendarExport.seat/1`."
  @spec seat_calendar_export(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  defdelegate seat_calendar_export(token), to: CalendarExport, as: :seat

  @doc """
  Where the booker of `meeting` downloads its calendar file. See
  `Tymeslot.Meetings.CalendarExport.for_booker/1`.
  """
  @spec booker_calendar(map()) :: {:seat, String.t()} | {:meeting, String.t()} | :none
  defdelegate booker_calendar(meeting), to: CalendarExport, as: :for_booker

  @doc """
  Dismisses the calendar sync status banner for a meeting by recording the current timestamp.

  Returns `{:ok, meeting}` on success or `{:error, :not_found}` if the meeting does not exist.
  """
  @spec dismiss_calendar_sync_status(String.t(), integer()) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def dismiss_calendar_sync_status(meeting_id, user_id) do
    MeetingCalendarQueries.dismiss_calendar_sync_status(meeting_id, user_id)
  end

  @doc """
  The time `meeting` can follow its moved calendar event to, or why it cannot.
  See `Tymeslot.Meetings.CalendarMove.offer/1`.
  """
  @spec calendar_move_offer(MeetingSchema.t()) ::
          {:ok, CalendarMove.offer()} | {:error, CalendarMove.refusal()}
  defdelegate calendar_move_offer(meeting), to: CalendarMove, as: :offer

  @doc """
  The calendar-move offers for the movable meetings among `meetings`, keyed by
  meeting id. See `Tymeslot.Meetings.CalendarMove.offers/1`.
  """
  @spec calendar_move_offers([MeetingSchema.t()]) :: %{String.t() => CalendarMove.offer()}
  defdelegate calendar_move_offers(meetings), to: CalendarMove, as: :offers

  @doc """
  Moves the organiser's booking to its calendar event's current time, provided
  it is still the `confirmed` offer the host agreed to. See
  `Tymeslot.Meetings.CalendarMove.move/3`.
  """
  @spec move_to_calendar_time(String.t(), integer(), CalendarMove.offer()) ::
          {:ok, MeetingSchema.t()} | {:error, CalendarMove.move_error()}
  defdelegate move_to_calendar_time(meeting_id, organizer_user_id, confirmed),
    to: CalendarMove,
    as: :move

  @doc """
  Applies an externally detected calendar change (`:deleted` or `:modified`)
  to the meeting linked to the given provider event, if any.

  This is the entry point the Calendar context uses when a sync worker
  detects that a provider event linked to a meeting changed externally.
  Owns all meeting-side consequences: sync-status updates, auto-cancellation
  on external deletion, and host notifications.

  `snapshot_at:` is when the read that saw the change began; see
  `Tymeslot.Meetings.ExternalCalendarChanges.apply_change/5`.
  """
  defdelegate apply_external_calendar_change(
                calendar_integration_id,
                provider_event_id,
                uid,
                signal,
                opts \\ []
              ),
              to: ExternalCalendarChanges,
              as: :apply_change

  @doc """
  Applies an external calendar change signal to a meeting already in hand.

  The identifier-free counterpart of `apply_external_calendar_change/4`, for
  callers that resolved the meeting themselves, such as a batch that matched many
  events in one query rather than two lookups per event.
  """
  defdelegate apply_external_calendar_change_to_meeting(meeting, signal),
    to: ExternalCalendarChanges,
    as: :apply_change_to_meeting

  @doc """
  Moves a meeting's end to the one the host gave its provider event, when the
  host lengthened or shortened it without moving its start.
  """
  defdelegate apply_external_end_change(meeting, end_time),
    to: ExternalCalendarChanges,
    as: :apply_end_change

  @doc """
  Records the end the host's calendar event shows for a meeting found in step
  with it, as the end a later end change is measured against.
  """
  defdelegate record_seen_calendar_end(meeting, end_time), to: ExternalCalendarChanges

  @doc """
  Clears an `"externally_modified"` flag on a meeting whose provider event
  agrees with it again.

  The counterpart of `apply_external_calendar_change/4` with a `:modified`
  signal: detection is stateless, so a sync pass that finds the two sides in
  agreement is the only thing that can retire a flag an earlier pass raised.
  """
  defdelegate resolve_external_calendar_change(meeting),
    to: ExternalCalendarChanges,
    as: :resolve_modification

  @doc """
  Looks up a meeting linked to a calendar event by provider event ID or UID.

  Returns `{:ok, meeting}` or `{:error, :not_found}`. Tries
  `provider_event_id` first, falls back to `uid`.
  """
  defdelegate find_meeting_by_calendar_event(calendar_integration_id, provider_event_id, uid),
    to: ExternalCalendarChanges,
    as: :find_linked_meeting

  @doc """
  Returns the meetings linked to the given integration that share any of
  `identifiers`, keyed by every identifier each matched meeting carries.
  """
  defdelegate list_meetings_by_calendar_identifiers(calendar_integration_id, identifiers),
    to: MeetingCalendarQueries,
    as: :list_by_calendar_identifiers

  @doc """
  Returns the subset of `identifiers` carried by any meeting the organiser
  `organizer_user_id` organises, in any status and through any integration.
  """
  defdelegate organizer_calendar_identifiers(organizer_user_id, identifiers),
    to: MeetingCalendarQueries

  @doc """
  Returns the non-blank identifiers by which `record` — a meeting or a cached
  provider calendar event — is matched to its counterpart on the other side.
  """
  defdelegate calendar_event_identifiers(record), to: CalendarEventLink, as: :identifiers

  @doc """
  Collects every calendar-event identifier across `records` into one set, for
  matching many records against many.
  """
  defdelegate calendar_identifier_set(records), to: CalendarEventLink, as: :identifier_set

  @doc """
  Whether `record` shares a calendar-event identifier with `identifier_set`,
  i.e. whether a meeting and a cached provider event describe the same event.
  """
  defdelegate linked_to_calendar_event?(record, identifier_set),
    to: CalendarEventLink,
    as: :linked?

  @doc """
  Drops from `records` every calendar event that mirrors `meeting`, so a
  meeting's own provider event never counts as a conflict with itself. `nil`
  leaves `records` untouched.
  """
  defdelegate reject_calendar_event_mirrors(records, meeting),
    to: CalendarEventLink,
    as: :reject_mirrors

  @doc """
  Merges the organiser's live bookings in `[from, to)` into `calendar_events`
  as busy periods, so a booking blocks its own slot whether or not it has
  reached the host's calendar. See `Tymeslot.Meetings.BusyPeriods`.
  """
  defdelegate merge_busy_periods(calendar_events, organizer_user_id, from, to),
    to: BusyPeriods,
    as: :merge

  # =====================================
  # Analytics Query Functions
  # =====================================

  @doc "Counts all bookings (any status) for an organizer in the window; analytics volume primitive."
  @spec count_bookings(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_bookings(organizer_user_id, from, to), to: MeetingAnalyticsQueries

  @doc "Booking counts grouped by `utm_source` (set rows only); primitive for `Analytics.attribution_table/3`."
  @spec bookings_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), bookings: non_neg_integer()}
        ]
  defdelegate bookings_by_utm_source(organizer_user_id, from, to),
    to: MeetingAnalyticsQueries,
    as: :count_by_utm_source

  @doc "Counts distinct converting visitors (bookings carrying a `visitor_hash`) in the window."
  @spec count_converting_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_converting_visitors(organizer_user_id, from, to), to: MeetingAnalyticsQueries

  @doc """
  Of `organizer_user_ids`, those who have had a real booking: not cancelled,
  booked by someone other than the organiser, group meetings included. See
  `Tymeslot.Meetings.MeetingAnalyticsQueries.organisers_with_real_booking/1`.
  """
  @spec organisers_with_real_booking([integer()]) :: [integer()]
  defdelegate organisers_with_real_booking(organizer_user_ids), to: MeetingAnalyticsQueries

  @doc "Distinct converting-visitor counts grouped by `utm_source`; primitive for `Analytics.attribution_table/3`."
  @spec converting_visitors_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), converting_visitors: non_neg_integer()}
        ]
  defdelegate converting_visitors_by_utm_source(organizer_user_id, from, to),
    to: MeetingAnalyticsQueries
end
