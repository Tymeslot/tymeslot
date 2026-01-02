defmodule Tymeslot.DatabaseSchemas.MeetingTypeSchema do
  @moduledoc """
  Schema for meeting types that users can configure.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "meeting_types" do
    field(:name, :string)
    field(:description, :string)
    field(:duration_minutes, :integer)
    field(:icon, :string)
    field(:is_active, :boolean, default: true)
    field(:allow_video, :boolean, default: false)
    field(:sort_order, :integer, default: 0)

    belongs_to(:user, Tymeslot.DatabaseSchemas.UserSchema)
    belongs_to(:video_integration, Tymeslot.DatabaseSchemas.VideoIntegrationSchema)

    timestamps()
  end

  @valid_icons [
    "none",
    "hero-bolt",
    "hero-chat-bubble-left-right",
    "hero-hand-raised",
    "hero-chart-bar",
    "hero-flag",
    "hero-clock",
    "hero-phone",
    "hero-light-bulb",
    "hero-wrench-screwdriver",
    "hero-book-open",
    "hero-rocket-launch",
    "hero-beaker"
  ]

  @doc """
  Changeset for creating/updating meeting types.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(meeting_type, attrs) do
    meeting_type
    |> cast(attrs, [
      :name,
      :description,
      :duration_minutes,
      :icon,
      :is_active,
      :allow_video,
      :sort_order,
      :user_id,
      :video_integration_id
    ])
    |> validate_required([:name, :duration_minutes, :user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_number(:duration_minutes, greater_than: 0, less_than_or_equal_to: 480)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_inclusion(:icon, @valid_icons, message: "must be one of the available icons")
    |> validate_video_integration()
    |> unique_constraint([:user_id, :name],
      message: "You already have a meeting type with this name"
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:video_integration_id)
  end

  @doc """
  Simple changeset for toggling active status.
  Only validates the is_active field without checking video integration requirements.
  """
  @spec toggle_active_changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def toggle_active_changeset(meeting_type, attrs) do
    cast(meeting_type, attrs, [:is_active])
  end

  # Validate that video integration is set when allow_video is true
  defp validate_video_integration(changeset) do
    allow_video = get_field(changeset, :allow_video)
    video_integration_id = get_field(changeset, :video_integration_id)

    if allow_video && is_nil(video_integration_id) do
      add_error(changeset, :video_integration_id, "is required when video meetings are enabled")
    else
      changeset
    end
  end

  @doc """
  Returns the list of valid icons for meeting types.
  """
  @spec valid_icons() :: [String.t()]
  def valid_icons, do: @valid_icons

  @doc """
  Returns the list of valid icons with their display names.
  """
  @spec valid_icons_with_names() :: [{String.t(), String.t()}]
  def valid_icons_with_names do
    [
      {"none", "No Icon"},
      {"hero-bolt", "Lightning - Quick meetings"},
      {"hero-chat-bubble-left-right", "Chat - Discussion meetings"},
      {"hero-hand-raised", "Hand - Business meetings"},
      {"hero-chart-bar", "Chart - Analysis meetings"},
      {"hero-flag", "Flag - Strategic meetings"},
      {"hero-clock", "Clock - Scheduled meetings"},
      {"hero-phone", "Phone - Call meetings"},
      {"hero-light-bulb", "Light Bulb - Brainstorming"},
      {"hero-wrench-screwdriver", "Wrench - Technical meetings"},
      {"hero-book-open", "Book - Learning meetings"},
      {"hero-rocket-launch", "Rocket - Project meetings"},
      {"hero-beaker", "Beaker - Casual meetings"}
    ]
  end
end
