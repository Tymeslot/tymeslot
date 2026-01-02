defmodule Tymeslot.Integrations.Calendar.Utils.EventValidator do
  @moduledoc """
  Validates event data before sending to providers.
  """
  import Ecto.Changeset

  @spec validate(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def validate(attrs) when is_map(attrs) do
    types = %{
      uid: :string,
      summary: :string,
      description: :string,
      location: :string,
      start_time: :utc_datetime,
      end_time: :utc_datetime,
      timezone: :string,
      attendee_name: :string,
      attendee_email: :string
    }

    changeset =
      {%{}, types}
      |> cast(attrs, Map.keys(types))
      |> validate_required([:start_time, :end_time])
      |> ensure_end_after_start()

    case changeset do
      %Ecto.Changeset{valid?: true} -> {:ok, attrs}
      changeset -> {:error, changeset}
    end
  end

  defp ensure_end_after_start(%Ecto.Changeset{} = changeset) do
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)

    if start_time && end_time && DateTime.compare(end_time, start_time) != :gt do
      add_error(changeset, :end_time, "must be after start_time")
    else
      changeset
    end
  end
end
