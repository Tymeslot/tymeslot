defmodule Tymeslot.Meetings.MeetingSchema do
  @moduledoc """
  Ecto schema for meetings with comprehensive fields for calendar integration,
  video conferencing, and meeting lifecycle management.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.ChangesetValidators.TimeOrder
  alias Tymeslot.ChangesetValidators.TrackingParams
  alias Tymeslot.Locales

  @type t :: %__MODULE__{
          id: binary() | nil,
          uid: String.t() | nil,
          title: String.t() | nil,
          summary: String.t() | nil,
          description: String.t() | nil,
          start_time: DateTime.t() | nil,
          end_time: DateTime.t() | nil,
          duration: integer() | nil,
          location: String.t() | nil,
          meeting_type: String.t() | nil,
          organizer_name: String.t() | nil,
          organizer_email: String.t() | nil,
          organizer_title: String.t() | nil,
          organizer_user_id: integer() | nil,
          calendar_integration_id: integer() | nil,
          calendar_path: String.t() | nil,
          attendee_name: String.t() | nil,
          attendee_email: String.t() | nil,
          attendee_message: String.t() | nil,
          attendee_phone: String.t() | nil,
          attendee_company: String.t() | nil,
          attendee_timezone: String.t() | nil,
          attendee_locale: String.t(),
          view_url: String.t() | nil,
          reschedule_url: String.t() | nil,
          cancel_url: String.t() | nil,
          meeting_url: String.t() | nil,
          video_room_id: String.t() | nil,
          video_provider: String.t() | nil,
          organizer_video_url: String.t() | nil,
          attendee_video_url: String.t() | nil,
          video_room_enabled: boolean(),
          video_room_created_at: DateTime.t() | nil,
          video_room_expires_at: DateTime.t() | nil,
          reminder_time: String.t() | nil,
          default_reminder_time: String.t() | nil,
          reminders: [map()] | nil,
          reminders_sent: [map()] | nil,
          status: String.t(),
          cancelled_at: DateTime.t() | nil,
          cancellation_reason: String.t() | nil,
          reschedule_requested_at: DateTime.t() | nil,
          organizer_email_sent: boolean(),
          attendee_email_sent: boolean(),
          reminder_email_sent: boolean(),
          calendar_sync_status: String.t() | nil,
          calendar_sync_status_dismissed_at: DateTime.t() | nil,
          provider_event_id: String.t() | nil,
          ical_sequence: integer(),
          last_notified_state: map(),
          custom_fields_snapshot: [map()],
          custom_field_answers: map(),
          show_as_free: boolean(),
          attachments_snapshot: [map()],
          utm_source: String.t() | nil,
          utm_medium: String.t() | nil,
          utm_campaign: String.t() | nil,
          utm_content: String.t() | nil,
          utm_term: String.t() | nil,
          referrer_host: String.t() | nil,
          tracking_params: map(),
          visitor_hash: String.t() | nil,
          organizer_user: any() | Ecto.Association.NotLoaded.t() | nil,
          calendar_integration: any() | Ecto.Association.NotLoaded.t() | nil,
          video_integration: any() | Ecto.Association.NotLoaded.t() | nil,
          meeting_type_ref: any() | Ecto.Association.NotLoaded.t() | nil,
          guests: [Tymeslot.Meetings.GuestSchema.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meetings" do
    field(:uid, :string)
    field(:title, :string)
    field(:summary, :string)
    field(:description, :string)
    field(:start_time, :utc_datetime)
    field(:end_time, :utc_datetime)
    field(:duration, :integer)
    field(:location, :string)
    field(:meeting_type, :string)

    # Organizer details
    field(:organizer_name, :string)
    field(:organizer_email, :string)
    field(:organizer_title, :string)

    belongs_to(:organizer_user, Tymeslot.Auth.UserSchema,
      foreign_key: :organizer_user_id,
      type: :id
    )

    # Calendar integration tracking
    belongs_to(:calendar_integration, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema,
      type: :id
    )

    belongs_to(:video_integration, Tymeslot.Integrations.Video.VideoIntegrationSchema, type: :id)

    belongs_to(:meeting_type_ref, Tymeslot.MeetingTypes.MeetingTypeSchema,
      foreign_key: :meeting_type_id,
      type: :id
    )

    field(:calendar_path, :string)

    # Attendee details
    field(:attendee_name, :string)
    field(:attendee_email, :string)
    field(:attendee_message, :string)
    field(:attendee_phone, :string)
    field(:attendee_company, :string)
    field(:attendee_timezone, :string)
    field(:attendee_locale, :string, default: "en")

    # URLs and links
    field(:view_url, :string)
    field(:reschedule_url, :string)
    field(:cancel_url, :string)
    field(:meeting_url, :string)

    # Video room integration
    field(:video_room_id, :string)
    # Retained independently of `video_integration_id` so a meeting still knows
    # where its room lives after the integration is deleted and the foreign key
    # nulls the link.
    field(:video_provider, :string)
    field(:organizer_video_url, :string)
    field(:attendee_video_url, :string)
    field(:video_room_enabled, :boolean, default: false)
    field(:video_room_created_at, :utc_datetime)
    field(:video_room_expires_at, :utc_datetime)

    # Reminder settings
    field(:reminder_time, :string)
    field(:default_reminder_time, :string)
    field(:reminders, {:array, :map}, default: nil)
    field(:reminders_sent, {:array, :map}, default: nil)

    # Status tracking
    field(:status, :string, default: "pending")
    field(:cancelled_at, :utc_datetime)
    field(:cancellation_reason, :string)
    # Set while an organizer reschedule request is pending; independent of
    # `status` (see `Tymeslot.Meetings.MeetingState`). Cleared once the
    # attendee books a new time.
    field(:reschedule_requested_at, :utc_datetime)

    # Email tracking
    field(:organizer_email_sent, :boolean, default: false)
    field(:attendee_email_sent, :boolean, default: false)
    field(:reminder_email_sent, :boolean, default: false)

    # External calendar sync
    field(:calendar_sync_status, :string)
    field(:calendar_sync_status_dismissed_at, :utc_datetime)
    field(:provider_event_id, :string)

    # Attendee notification tracking
    field(:ical_sequence, :integer, default: 0)
    field(:last_notified_state, :map, default: %{})

    # Custom booking fields
    field(:custom_fields_snapshot, {:array, :map}, default: [])
    field(:custom_field_answers, :map, default: %{})

    # Snapshot of the meeting type's show_as_free setting at booking time —
    # drives TRANSP/transparency on the calendar event written to the host.
    field(:show_as_free, :boolean, default: false)

    # Snapshot of the meeting type's host-uploaded attachments at booking time.
    field(:attachments_snapshot, {:array, :map}, default: [])

    # Guests added by the attendee at booking time
    has_many(:guests, Tymeslot.Meetings.GuestSchema,
      foreign_key: :meeting_id,
      preload_order: [asc: :inserted_at],
      on_delete: :delete_all
    )

    # Source attribution
    field(:utm_source, :string)
    field(:utm_medium, :string)
    field(:utm_campaign, :string)
    field(:utm_content, :string)
    field(:utm_term, :string)
    field(:referrer_host, :string)
    # Cookieless join key to the booking-page view in analytics_events.
    field(:visitor_hash, :string)
    field(:tracking_params, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @required_fields [
    :uid,
    :title,
    :start_time,
    :end_time,
    :organizer_name,
    :organizer_email,
    :attendee_name,
    :attendee_email
  ]

  @optional_fields [
    :summary,
    :description,
    :duration,
    :location,
    :meeting_type,
    :meeting_type_id,
    :organizer_title,
    :organizer_user_id,
    :calendar_integration_id,
    :video_integration_id,
    :calendar_path,
    :attendee_message,
    :attendee_phone,
    :attendee_company,
    :attendee_timezone,
    :attendee_locale,
    :view_url,
    :reschedule_url,
    :cancel_url,
    :meeting_url,
    :video_room_id,
    :video_provider,
    :organizer_video_url,
    :attendee_video_url,
    :video_room_enabled,
    :video_room_created_at,
    :video_room_expires_at,
    :reminder_time,
    :default_reminder_time,
    :reminders,
    :reminders_sent,
    :status,
    :organizer_email_sent,
    :attendee_email_sent,
    :reminder_email_sent,
    :cancelled_at,
    :cancellation_reason,
    :reschedule_requested_at,
    :calendar_sync_status,
    :calendar_sync_status_dismissed_at,
    :provider_event_id,
    :ical_sequence,
    :last_notified_state,
    :custom_fields_snapshot,
    :custom_field_answers,
    :show_as_free,
    :attachments_snapshot,
    :utm_source,
    :utm_medium,
    :utm_campaign,
    :utm_content,
    :utm_term,
    :referrer_host,
    :tracking_params,
    :visitor_hash
  ]

  @valid_statuses [
    "pending",
    "confirmed",
    "cancelled",
    "completed",
    "reschedule_requested",
    "awaiting_payment",
    "expired"
  ]

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(meeting, attrs) do
    meeting
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> EmailChangeset.validate_email(:organizer_email)
    |> EmailChangeset.validate_email(:attendee_email)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_required([:attendee_locale])
    |> validate_inclusion(:attendee_locale, supported_locale_codes(),
      message: "is not a supported locale"
    )
    |> TimeOrder.validate_time_order(:start_time, :end_time)
    |> validate_length(:utm_source, max: 255)
    |> validate_length(:utm_medium, max: 255)
    |> validate_length(:utm_campaign, max: 255)
    |> validate_length(:utm_content, max: 255)
    |> validate_length(:utm_term, max: 255)
    |> validate_length(:referrer_host, max: 255)
    |> validate_length(:visitor_hash, max: 64)
    # Google Calendar's documented maximum event id length.
    |> validate_length(:provider_event_id, max: 1024)
    |> TrackingParams.validate_tracking_params(:tracking_params)
    |> calculate_duration()
    |> unique_constraint(:uid)
    |> unique_constraint([:organizer_user_id, :start_time],
      name: :unique_confirmed_meeting_per_organizer_at_time,
      message: "You already have a confirmed meeting at this time."
    )
    |> check_constraint(:end_time, name: :meetings_end_after_start)
  end

  defp calculate_duration(changeset) do
    # Only calculate duration if not provided
    if get_change(changeset, :duration) do
      changeset
    else
      start_time = get_field(changeset, :start_time)
      end_time = get_field(changeset, :end_time)

      if start_time && end_time do
        duration = DateTime.diff(end_time, start_time, :minute)
        put_change(changeset, :duration, duration)
      else
        changeset
      end
    end
  end

  @doc """
  Returns all valid status values
  """
  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses

  @doc """
  Checks if a meeting is in the future
  """
  @spec future?(t()) :: boolean
  def future?(%__MODULE__{start_time: start_time}) do
    DateTime.compare(start_time, DateTime.utc_now()) == :gt
  end

  @doc """
  Checks if a meeting is currently happening
  """
  @spec current?(t()) :: boolean
  def current?(%__MODULE__{start_time: start_time, end_time: end_time}) do
    now = DateTime.utc_now()
    DateTime.compare(start_time, now) != :gt && DateTime.compare(end_time, now) == :gt
  end

  defp supported_locale_codes, do: Locales.supported_codes()
end
