defmodule Tymeslot.Integrations.Calendar.Utils.EventValidator do
  @moduledoc """
  Validates event data before sending to providers.

  Timed events require `:start_time`/`:end_time` as UTC datetimes. All-day
  events (signalled by `all_day: true` or `Date`-typed start/end) instead
  require `:start_time`/`:end_time` as `Date` structs and skip the
  utc_datetime requirement entirely.
  """
  import Ecto.Changeset

  @spec validate(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def validate(attrs) when is_map(attrs) do
    if all_day?(attrs) do
      validate_all_day(attrs)
    else
      validate_timed(attrs)
    end
  end

  defp validate_timed(attrs),
    do: do_validate(attrs, :utc_datetime, &ensure_end_after_start/1)

  defp validate_all_day(attrs),
    do: do_validate(attrs, :date, &ensure_end_not_before_start/1)

  defp do_validate(attrs, time_type, comparator_fun) do
    types = Map.merge(base_types(), %{start_time: time_type, end_time: time_type})

    {%{}, types}
    |> cast(attrs, Map.keys(types))
    |> validate_required([:start_time, :end_time])
    |> comparator_fun.()
    |> finalise(attrs)
  end

  defp base_types do
    %{
      uid: :string,
      summary: :string,
      description: :string,
      location: :string,
      timezone: :string,
      attendee_name: :string,
      attendee_email: :string
    }
  end

  defp finalise(%Ecto.Changeset{valid?: true}, attrs), do: {:ok, attrs}
  defp finalise(%Ecto.Changeset{} = changeset, _attrs), do: {:error, changeset}

  # An event is all-day when it carries an explicit `all_day: true` flag or when
  # its start/end are date-only `Date` structs rather than datetimes.
  defp all_day?(%{all_day: true}), do: true
  defp all_day?(%{start_time: %Date{}}), do: true
  defp all_day?(%{"start_time" => %Date{}}), do: true
  defp all_day?(_attrs), do: false

  defp ensure_end_after_start(%Ecto.Changeset{} = changeset) do
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)

    if start_time && end_time && DateTime.compare(end_time, start_time) != :gt do
      add_error(changeset, :end_time, "must be after start_time")
    else
      changeset
    end
  end

  defp ensure_end_not_before_start(%Ecto.Changeset{} = changeset) do
    start_date = get_field(changeset, :start_time)
    end_date = get_field(changeset, :end_time)

    if start_date && end_date && Date.compare(end_date, start_date) == :lt do
      add_error(changeset, :end_time, "must not be before start_time")
    else
      changeset
    end
  end
end
