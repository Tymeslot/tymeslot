defmodule Tymeslot.Integrations.Calendar.ColourOverride do
  @moduledoc """
  A user's explicit, durable per-event colour choice. Decoupled from the
  provider sync cache (which re-sync overwrites), so the choice survives
  re-sync and works even where the provider has no per-event colour (Outlook).

  Exactly one target is set: a Tymeslot booking (`meeting_id`) or an external
  event (`calendar_integration_id` + `provider_uid`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.EventColour

  @type t :: %__MODULE__{}

  schema "event_colour_overrides" do
    field :colour, :string
    field :user_id, :id
    field :meeting_id, Ecto.UUID
    field :calendar_integration_id, :id
    field :provider_uid, :string
    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(override, attrs) do
    override
    |> cast(attrs, [:user_id, :colour, :meeting_id, :calendar_integration_id, :provider_uid])
    |> validate_required([:user_id, :colour])
    |> validate_change(:colour, fn :colour, value ->
      if EventColour.valid_key?(value), do: [], else: [colour: "is not a valid palette key"]
    end)
    |> validate_exactly_one_target()
    |> unique_constraint([:user_id, :meeting_id],
      name: :event_colour_overrides_user_meeting_index
    )
    |> unique_constraint([:user_id, :calendar_integration_id, :provider_uid],
      name: :event_colour_overrides_user_external_index
    )
  end

  defp validate_exactly_one_target(changeset) do
    case {get_field(changeset, :meeting_id), get_field(changeset, :calendar_integration_id),
          get_field(changeset, :provider_uid)} do
      {meeting_id, nil, nil} when meeting_id != nil -> changeset
      {nil, integration_id, uid} when integration_id != nil and uid != nil -> changeset
      _other -> add_error(changeset, :base, "exactly one of meeting or external target required")
    end
  end
end
