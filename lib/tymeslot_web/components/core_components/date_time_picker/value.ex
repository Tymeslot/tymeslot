defmodule TymeslotWeb.Components.CoreComponents.DateTimePicker.Value do
  @moduledoc """
  Reads what a `<.datetime_picker>` posts.

  A complete value is `YYYY-MM-DDTHH:MM`. A half-filled one is posted as it
  stands, `YYYY-MM-DD` with no time or `THH:MM` with no date, so a form can
  tell a field left blank from one left unfinished instead of reading the
  latter as blank and saving without it. The picker shows `message/1` under
  itself for an unfinished value; a form only has to refuse to save one, which
  `parse/1` makes the default.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  @type unfinished :: :missing_time | :missing_date

  @doc """
  The value as a `NaiveDateTime`, `nil` for a blank field, or why it cannot be
  read: `:missing_time` or `:missing_date` for a half-filled one, `:invalid`
  for anything else.
  """
  @spec parse(term()) :: {:ok, NaiveDateTime.t() | nil} | {:error, unfinished() | :invalid}
  def parse(value) when value in [nil, ""], do: {:ok, nil}

  def parse(value) when is_binary(value) do
    case unfinished(value) do
      nil -> read(value)
      reason -> {:error, reason}
    end
  end

  def parse(_value), do: {:error, :invalid}

  @doc "Which half a half-filled value lacks, or nil for any other value."
  @spec unfinished(term()) :: unfinished() | nil
  def unfinished(<<_date::binary-size(10)>> = value) do
    if match?({:ok, _date}, Date.from_iso8601(value)), do: :missing_time
  end

  def unfinished(<<"T", time::binary-size(5)>>) do
    if match?({:ok, _time}, Time.from_iso8601(time <> ":00")), do: :missing_date
  end

  def unfinished(_value), do: nil

  @doc "The inline error for a half-filled value."
  @spec message(unfinished()) :: String.t()
  def message(:missing_time), do: dgettext("common", "Add a time")
  def message(:missing_date), do: dgettext("common", "Add a date")

  # A browser set to show seconds posts them; most do not.
  defp read(value) do
    value = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, naive}
      {:error, _reason} -> {:error, :invalid}
    end
  end
end
