defmodule Tymeslot.Meetings.ParticipantSchema do
  @moduledoc """
  Ecto schema for a participant on a group meeting.

  Solo meeting types (`max_participants == 1`) keep the `attendee_*` fields
  on the meeting row exactly as before. Group meetings instead carry one
  participant row per booker; each participant manages their own seat via an
  unguessable `management_token` and is soft-cancelled through
  `cancelled_at` so freed seats become bookable again.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.MeetingSchema

  @type t :: %__MODULE__{
          id: binary() | nil,
          meeting_id: binary() | nil,
          name: String.t() | nil,
          email: String.t() | nil,
          phone: String.t() | nil,
          company: String.t() | nil,
          message: String.t() | nil,
          timezone: String.t() | nil,
          locale: String.t(),
          custom_field_answers: map(),
          management_token: String.t() | nil,
          cancelled_at: DateTime.t() | nil,
          meeting: MeetingSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          guests: [Tymeslot.Meetings.GuestSchema.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meeting_participants" do
    field(:name, :string)
    field(:email, :string)
    field(:phone, :string)
    field(:company, :string)
    field(:message, :string)
    field(:timezone, :string)
    field(:locale, :string, default: "en")
    field(:custom_field_answers, :map, default: %{})
    field(:management_token, :string)
    field(:cancelled_at, :utc_datetime)

    belongs_to(:meeting, MeetingSchema, type: :binary_id)

    has_many(:guests, Tymeslot.Meetings.GuestSchema,
      foreign_key: :participant_id,
      preload_order: [asc: :inserted_at]
    )

    timestamps(type: :utc_datetime)
  end

  @token_bytes 32

  @doc """
  Changeset for adding a participant to a group meeting.

  Normalises the email, validates its format the same way `MeetingSchema`
  validates `attendee_email`, and generates an unguessable
  `management_token` when one is not already present.
  """
  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(participant, attrs) do
    participant
    |> cast(attrs, [
      :meeting_id,
      :name,
      :email,
      :phone,
      :company,
      :message,
      :timezone,
      :locale,
      :custom_field_answers,
      :management_token
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:meeting_id, :name, :email, :timezone, :locale])
    |> EmailChangeset.validate_email(:email)
    |> validate_inclusion(:locale, supported_locale_codes(), message: "is not a supported locale")
    |> ensure_management_token()
    |> unique_constraint(:management_token)
    |> foreign_key_constraint(:meeting_id)
  end

  @doc "Changeset for soft-cancelling a participant at the given time."
  @spec cancel_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def cancel_changeset(participant, cancelled_at) do
    cast(participant, %{cancelled_at: cancelled_at}, [:cancelled_at])
  end

  @doc "True while the participant still holds their seat (not cancelled)."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{cancelled_at: nil}), do: true
  def live?(%__MODULE__{}), do: false

  @doc "Generates an unguessable, URL-safe management token."
  @spec generate_token() :: String.t()
  def generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp ensure_management_token(changeset) do
    case get_field(changeset, :management_token) do
      nil -> put_change(changeset, :management_token, generate_token())
      _present -> changeset
    end
  end

  defp normalize_email(nil), do: nil

  defp normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp supported_locale_codes, do: Locales.supported_codes()
end
