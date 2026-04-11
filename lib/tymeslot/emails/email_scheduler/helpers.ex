defmodule Tymeslot.Emails.EmailScheduler.Helpers do
  @moduledoc "Shared helpers for EmailScheduler sub-modules."

  alias Ecto.Changeset

  @doc """
  Formats an Oban insert error into a loggable string.
  """
  @spec format_insert_error(term()) :: term()
  def format_insert_error(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  def format_insert_error(other), do: inspect(other)
end
