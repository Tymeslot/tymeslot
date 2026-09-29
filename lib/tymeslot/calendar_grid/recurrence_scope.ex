defmodule Tymeslot.CalendarGrid.RecurrenceScope do
  @moduledoc "Which occurrences of a recurring event an edit applies to."

  @type t :: :this_only | :following | :all

  @values [:this_only, :following, :all]

  @doc "Every scope, in the order a prompt offers them."
  @spec values() :: [t()]
  def values, do: @values

  @doc "Reads the scope a prompt button sends. Unknown input is `:error`."
  @spec parse(String.t() | nil) :: {:ok, t()} | :error
  def parse("this_only"), do: {:ok, :this_only}
  def parse("following"), do: {:ok, :following}
  def parse("all"), do: {:ok, :all}
  def parse(_other), do: :error
end
