defmodule Tymeslot.CalendarGrid.CalendarSetSchema.Member do
  @moduledoc """
  One calendar a set shows: an integration and one of its calendars, or the
  whole integration when `calendar_id` is nil (an account without a
  calendar list).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{integration_id: integer() | nil, calendar_id: String.t() | nil}

  @primary_key false
  embedded_schema do
    field :integration_id, :integer
    field :calendar_id, :string
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:integration_id, :calendar_id], empty_values: [])
    |> validate_required([:integration_id])
    |> validate_length(:calendar_id, min: 1, max: 255)
  end
end
