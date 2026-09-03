defmodule Tymeslot.MeetingTypes.ApprovalWindow do
  @moduledoc """
  Parsing for a meeting type's `approval_window_hours`, the deadline a host has
  to answer a booking request before it is released.

  The field arrives from two places with different levels of sanitisation: the
  raw form post handled by `Tymeslot.MeetingTypes.FormMapper`, which can carry
  an integer or anything else a client chooses to send, and the meeting-type
  LiveComponent's `phx-change` params, which are always strings or nil. Both
  need the same answer to the same question, so the parser lives here once
  rather than as a copy per caller: the two copies had already drifted, one
  accepting integers the other did not and each reporting failure differently.
  """

  @doc """
  Parses a submitted approval window into hours.

  Blank means "use the application default", which the domain resolves at read
  time rather than freezing today's value into every row, so it maps to
  `{:ok, nil}`. Anything else unparseable ("abc", "-1", "2.5") is a genuine
  mistake, not a second spelling of blank: coercing it to nil would silently
  overwrite a previously saved window the moment the host mistypes, so it is
  surfaced as an error for the caller to show instead.

  The range itself is not checked here; that belongs to the changeset, which
  enforces `Tymeslot.Validation.Constraints.approval_window_hours_range/0`.
  """
  @spec parse(term()) :: {:ok, pos_integer() | nil} | {:error, :invalid_approval_window}
  def parse(nil), do: {:ok, nil}
  def parse(value) when is_integer(value) and value > 0, do: {:ok, value}

  def parse(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> parse_trimmed(trimmed)
    end
  end

  def parse(_value), do: {:error, :invalid_approval_window}

  defp parse_trimmed(trimmed) do
    case Integer.parse(trimmed) do
      {hours, ""} when hours > 0 -> {:ok, hours}
      _other -> {:error, :invalid_approval_window}
    end
  end
end
