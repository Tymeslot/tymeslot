defmodule Tymeslot.DatabaseSchemas.MeetingSchema do
  @moduledoc """
  Ecto schema for meetings with comprehensive fields for calendar integration,
  video conferencing, and meeting lifecycle management.
  """

  use Ecto.Schema
  import Ecto.Changeset

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
          view_url: String.t() | nil,
          reschedule_url: String.t() | nil,
          cancel_url: String.t() | nil,
          meeting_url: String.t() | nil,
          video_room_id: String.t() | nil,
          organizer_video_url: String.t() | nil,
          attendee_video_url: String.t() | nil,
          video_room_enabled: boolean(),
          video_room_created_at: DateTime.t() | nil,
          video_room_expires_at: DateTime.t() | nil,
          reminder_time: String.t() | nil,
          default_reminder_time: String.t() | nil,
          status: String.t(),
          cancelled_at: DateTime.t() | nil,
          cancellation_reason: String.t() | nil,
          organizer_email_sent: boolean(),
          attendee_email_sent: boolean(),
          reminder_email_sent: boolean(),
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

    belongs_to(:organizer_user, Tymeslot.DatabaseSchemas.UserSchema,
      foreign_key: :organizer_user_id,
      type: :id
    )

    # Calendar integration tracking
    belongs_to(:calendar_integration, Tymeslot.DatabaseSchemas.CalendarIntegrationSchema,
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

    # URLs and links
    field(:view_url, :string)
    field(:reschedule_url, :string)
    field(:cancel_url, :string)
    field(:meeting_url, :string)

    # Video room integration
    field(:video_room_id, :string)
    field(:organizer_video_url, :string)
    field(:attendee_video_url, :string)
    field(:video_room_enabled, :boolean, default: false)
    field(:video_room_created_at, :utc_datetime)
    field(:video_room_expires_at, :utc_datetime)

    # Calendar integration - .ics files are attached to emails

    # Reminder settings
    field(:reminder_time, :string)
    field(:default_reminder_time, :string)

    # Status tracking
    field(:status, :string, default: "pending")
    field(:cancelled_at, :utc_datetime)
    field(:cancellation_reason, :string)

    # Email tracking
    field(:organizer_email_sent, :boolean, default: false)
    field(:attendee_email_sent, :boolean, default: false)
    field(:reminder_email_sent, :boolean, default: false)

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
    :organizer_title,
    :organizer_user_id,
    :calendar_integration_id,
    :calendar_path,
    :attendee_message,
    :attendee_phone,
    :attendee_company,
    :attendee_timezone,
    :view_url,
    :reschedule_url,
    :cancel_url,
    :meeting_url,
    :video_room_id,
    :organizer_video_url,
    :attendee_video_url,
    :video_room_enabled,
    :video_room_created_at,
    :video_room_expires_at,
    :reminder_time,
    :default_reminder_time,
    :status,
    :organizer_email_sent,
    :attendee_email_sent,
    :reminder_email_sent,
    :cancelled_at,
    :cancellation_reason
  ]

  @valid_statuses ["pending", "confirmed", "cancelled", "completed", "reschedule_requested"]

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(meeting, attrs) do
    meeting
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:organizer_email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> validate_format(:attendee_email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_time_order()
    |> calculate_duration()
    |> unique_constraint(:uid)
  end

  defp validate_time_order(changeset) do
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)

    if start_time && end_time && DateTime.compare(end_time, start_time) != :gt do
      add_error(changeset, :end_time, "must be after start time")
    else
      changeset
    end
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
  Checks if a meeting is in the past
  """
  @spec past?(t()) :: boolean
  def past?(%__MODULE__{end_time: end_time}) do
    DateTime.compare(end_time, DateTime.utc_now()) == :lt
  end

  @doc """
  Checks if a meeting is currently happening
  """
  @spec current?(t()) :: boolean
  def current?(%__MODULE__{start_time: start_time, end_time: end_time}) do
    now = DateTime.utc_now()
    DateTime.compare(start_time, now) != :gt && DateTime.compare(end_time, now) == :gt
  end

  @doc """
  Returns the duration in human-readable format
  """
  @spec duration_text(t() | any) :: String.t()
  def duration_text(%__MODULE__{duration: duration}) when is_integer(duration) do
    cond do
      duration < 60 -> "#{duration} minutes"
      duration == 60 -> "1 hour"
      duration > 60 -> "#{Float.round(duration / 60, 1)} hours"
      true -> "Unknown duration"
    end
  end

  def duration_text(_), do: "Unknown duration"
end
