defmodule Tymeslot.Analytics.EventSchema do
  @moduledoc """
  Ecto schema for analytics events (page views and, in v2, funnel events).

  Owned by the `Tymeslot.Analytics` context. Inserts happen via
  `Tymeslot.Analytics.log_page_view/1`; do not insert directly.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.TrackingParams

  @type t :: %__MODULE__{
          id: integer() | nil,
          event_type: String.t() | nil,
          path: String.t() | nil,
          meeting_type_id: integer() | nil,
          user_id: integer() | nil,
          session_id: String.t() | nil,
          visitor_hash: String.t() | nil,
          utm_source: String.t() | nil,
          utm_medium: String.t() | nil,
          utm_campaign: String.t() | nil,
          utm_content: String.t() | nil,
          utm_term: String.t() | nil,
          referrer_host: String.t() | nil,
          tracking_params: map(),
          user_agent_family: String.t() | nil,
          device_type: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @valid_event_types ~w(booking_page_view)

  schema "analytics_events" do
    field(:event_type, :string)
    field(:path, :string)
    field(:meeting_type_id, :id)
    field(:user_id, :id)
    field(:session_id, :string)
    field(:visitor_hash, :string)
    field(:utm_source, :string)
    field(:utm_medium, :string)
    field(:utm_campaign, :string)
    field(:utm_content, :string)
    field(:utm_term, :string)
    field(:referrer_host, :string)
    field(:tracking_params, :map, default: %{})
    field(:user_agent_family, :string)
    field(:device_type, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w(event_type path visitor_hash)a
  @optional ~w(meeting_type_id user_id session_id utm_source utm_medium utm_campaign
               utm_content utm_term referrer_host tracking_params user_agent_family
               device_type)a

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:event_type, @valid_event_types)
    |> validate_length(:path, max: 255)
    |> validate_length(:session_id, max: 255)
    |> validate_length(:referrer_host, max: 255)
    |> TrackingParams.validate_tracking_params(:tracking_params)
  end

  @spec valid_event_types() :: [String.t()]
  def valid_event_types, do: @valid_event_types
end
