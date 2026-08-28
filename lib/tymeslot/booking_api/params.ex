defmodule Tymeslot.BookingApi.Params do
  @moduledoc """
  Parses and validates the JSON body of `POST /api/v1/bookings`.

  Validation is exhaustive rather than short-circuiting: a rejected body comes
  back with every offending field at once, so a caller correcting one field
  does not discover the next one on the following request.

  Unrecognised keys are ignored. Accepting them would tempt callers to smuggle
  attendee details the endpoint does not model into fields nothing reads.
  """

  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias Tymeslot.Timezones

  @typedoc "One rejected field and the reason it was rejected."
  @type violation :: %{field: String.t(), message: String.t()}

  @typedoc """
  A validated request. `end_time` and `duration_minutes` are mutually
  exclusive, and both may be absent when `meeting_type` supplies the duration.
  """
  @type t :: %{
          attendee_name: String.t(),
          attendee_email: String.t(),
          attendee_timezone: String.t(),
          start_time: DateTime.t(),
          end_time: DateTime.t() | nil,
          duration_minutes: pos_integer() | nil,
          title: String.t() | nil,
          meeting_type: String.t() | nil,
          guest_emails: [String.t()],
          force: boolean()
        }

  @name_max_length 255
  @title_max_length 255
  @slug_max_length 255
  @max_guests 20
  @max_duration_minutes 1440

  @doc """
  Validates a decoded JSON body.

  Returns `{:error, {:invalid_params, violations}}` with one violation per
  offending field, ordered as the fields are documented.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_params, [violation()]}}
  def parse(body) when is_map(body) do
    parsed = %{
      attendee_name: text(body, "attendee_name", @name_max_length),
      attendee_email: email(body, "attendee_email"),
      attendee_timezone: timezone(body, "attendee_timezone"),
      start_time: timestamp(body, "start_time"),
      end_time: optional_timestamp(body, "end_time"),
      duration_minutes: duration(body, "duration_minutes"),
      title: optional_text(body, "title", @title_max_length),
      meeting_type: optional_text(body, "meeting_type", @slug_max_length),
      guest_emails: guest_emails(body, "guest_emails"),
      force: flag(body, "force")
    }

    case violations(parsed) do
      [] -> {:ok, resolved(parsed)}
      violations -> {:error, {:invalid_params, violations}}
    end
  end

  def parse(_body), do: {:error, {:invalid_params, [violation("body", "must be a JSON object")]}}

  # Private — per-field parsing.
  #
  # Every parser answers either `{:ok, value}` or `{:error, message}`, so the
  # field results can be collected first and reported together, rather than the
  # first failure ending the pass.

  defp text(body, field, max_length) do
    case Map.get(body, field) do
      value when is_binary(value) -> non_empty(String.trim(value), field, max_length)
      nil -> {:error, "is required"}
      _other -> {:error, "must be a string"}
    end
  end

  defp non_empty("", _field, _max_length), do: {:error, "is required"}

  defp non_empty(value, _field, max_length) do
    if String.length(value) > max_length do
      {:error, "must be at most #{max_length} characters"}
    else
      {:ok, value}
    end
  end

  defp optional_text(body, field, max_length) do
    case Map.get(body, field) do
      nil -> {:ok, nil}
      value when is_binary(value) -> non_empty(String.trim(value), field, max_length)
      _other -> {:error, "must be a string"}
    end
  end

  defp email(body, field) do
    with {:ok, value} <- text(body, field, @name_max_length) do
      case EmailValidator.validate(value) do
        :ok -> {:ok, value}
        {:error, message} -> {:error, message}
      end
    end
  end

  defp timezone(body, field) do
    case Map.get(body, field) do
      nil ->
        {:ok, Timezones.fallback()}

      value when is_binary(value) ->
        if Timezones.valid?(value),
          do: {:ok, value},
          else: {:error, "is not a known IANA time zone"}

      _other ->
        {:error, "must be a string"}
    end
  end

  # ISO 8601 with an explicit offset. A naive timestamp is refused rather than
  # assumed to be UTC: guessing wrong moves the meeting by hours and neither
  # side would see it happen.
  defp timestamp(body, field) do
    case Map.get(body, field) do
      nil ->
        {:error, "is required"}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} ->
            {:ok, DateTime.truncate(datetime, :second)}

          {:error, :missing_offset} ->
            {:error, "must carry a UTC offset, e.g. 2026-09-01T09:00:00Z"}

          {:error, _reason} ->
            {:error, "must be an ISO 8601 timestamp"}
        end

      _other ->
        {:error, "must be a string"}
    end
  end

  defp optional_timestamp(body, field) do
    case Map.get(body, field) do
      nil -> {:ok, nil}
      _value -> timestamp(body, field)
    end
  end

  defp duration(body, field) do
    case Map.get(body, field) do
      nil ->
        {:ok, nil}

      value when is_integer(value) and value > 0 and value <= @max_duration_minutes ->
        {:ok, value}

      value when is_integer(value) ->
        {:error, "must be between 1 and #{@max_duration_minutes} minutes"}

      _other ->
        {:error, "must be an integer number of minutes"}
    end
  end

  defp guest_emails(body, field) do
    case Map.get(body, field) do
      nil -> {:ok, []}
      value when is_list(value) -> validate_guest_list(value)
      _other -> {:error, "must be an array of email addresses"}
    end
  end

  defp validate_guest_list(list) when length(list) > @max_guests,
    do: {:error, "must hold at most #{@max_guests} addresses"}

  defp validate_guest_list(list) do
    invalid = Enum.reject(list, &(is_binary(&1) and EmailValidator.validate(&1) == :ok))

    if invalid == [] do
      {:ok, list}
    else
      {:error, "contains #{length(invalid)} address(es) that are not valid email addresses"}
    end
  end

  defp flag(body, field) do
    case Map.get(body, field) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, "must be true or false"}
    end
  end

  # Private — cross-field rules and assembly

  defp violations(parsed) do
    field_violations(parsed) ++ combination_violations(parsed)
  end

  defp field_violations(parsed) do
    parsed
    |> Enum.sort_by(fn {field, _result} -> field_order(field) end)
    |> Enum.flat_map(fn
      {field, {:error, message}} -> [violation(to_string(field), message)]
      {_field, {:ok, _value}} -> []
    end)
  end

  # Ordered as the fields are documented, so two rejections of the same body
  # always read the same way.
  defp field_order(field) do
    order = [
      :attendee_name,
      :attendee_email,
      :attendee_timezone,
      :start_time,
      :end_time,
      :duration_minutes,
      :title,
      :meeting_type,
      :guest_emails,
      :force
    ]

    Enum.find_index(order, &(&1 == field)) || length(order)
  end

  # Cross-field rules only run once every field they read has parsed, so a
  # single bad timestamp does not also produce "end_time must be after
  # start_time" against a value that was never understood.
  defp combination_violations(parsed) do
    Enum.concat([
      duration_violations(parsed),
      ordering_violations(parsed),
      title_violations(parsed)
    ])
  end

  defp duration_violations(
         %{end_time: {:ok, end_time}, duration_minutes: {:ok, minutes}} = parsed
       ) do
    cond do
      not is_nil(end_time) and not is_nil(minutes) ->
        [violation("duration_minutes", "cannot be combined with end_time")]

      is_nil(end_time) and is_nil(minutes) and not supplies_duration?(parsed) ->
        [violation("end_time", "is required unless duration_minutes or meeting_type is given")]

      true ->
        []
    end
  end

  defp duration_violations(_parsed), do: []

  defp supplies_duration?(%{meeting_type: {:ok, slug}}), do: not is_nil(slug)
  defp supplies_duration?(_parsed), do: false

  defp ordering_violations(%{
         start_time: {:ok, start_time},
         end_time: {:ok, %DateTime{} = end_time}
       }) do
    if DateTime.compare(end_time, start_time) == :gt do
      []
    else
      [violation("end_time", "must be after start_time")]
    end
  end

  defp ordering_violations(_parsed), do: []

  defp title_violations(%{title: {:ok, nil}, meeting_type: {:ok, nil}}),
    do: [violation("title", "is required unless meeting_type is given")]

  defp title_violations(_parsed), do: []

  defp resolved(parsed) do
    Map.new(parsed, fn {field, {:ok, value}} -> {field, value} end)
  end

  defp violation(field, message), do: %{field: field, message: message}
end
