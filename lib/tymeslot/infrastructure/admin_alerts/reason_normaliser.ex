defmodule Tymeslot.Infrastructure.AdminAlerts.ReasonNormaliser do
  @moduledoc """
  Normalises arbitrary `reason` terms from admin alert call sites into a stable
  `%{code: atom() | nil, message: String.t()}` shape.

  Call sites pass reasons in whatever form they have — atoms, tagged tuples,
  exceptions, Ecto changesets, binaries, or arbitrary terms. Rendering them
  directly via `inspect/1` in alert emails produces inconsistent, sometimes
  cryptic output (e.g. `#Ecto.Changeset<...>`). This module gives the email
  template a uniform shape to render, so operators see readable context
  regardless of where the alert came from.

  `nil` is returned unchanged, so callers can pass `reason: nil` to omit the
  reason fields from the alert payload entirely.
  """

  alias Ecto.Changeset

  @type normalised :: %{code: atom() | nil, message: String.t()}

  # Cap reason messages at 500 characters. Exception.message/1 and inspect/1 can
  # both embed large per-occurrence data (Postgrex.Error query results, big Ecto
  # graphs, etc.). Unbounded strings bloat Oban job args (JSONB) and JSON logs.
  @max_message_length 500

  @spec normalise(term()) :: normalised() | nil
  def normalise(nil), do: nil

  def normalise(exception) when is_exception(exception) do
    %{code: exception.__struct__, message: exception |> Exception.message() |> cap_message()}
  end

  def normalise(%Changeset{} = changeset) do
    %{code: :changeset_invalid, message: format_changeset(changeset)}
  end

  def normalise({code, message}) when is_atom(code) and is_binary(message) do
    %{code: code, message: cap_message(message)}
  end

  def normalise({code, detail}) when is_atom(code) do
    %{code: code, message: bounded_inspect(detail)}
  end

  def normalise(atom) when is_atom(atom) do
    %{code: atom, message: Atom.to_string(atom)}
  end

  def normalise(binary) when is_binary(binary) do
    %{code: nil, message: cap_message(binary)}
  end

  def normalise(term) do
    %{code: nil, message: bounded_inspect(term)}
  end

  defp format_changeset(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} ->
      "#{field}: #{Enum.join(errors, ", ")}"
    end)
    |> cap_message()
  end

  defp bounded_inspect(term) do
    term
    |> inspect(limit: 50, printable_limit: 200)
    |> cap_message()
  end

  defp cap_message(message) when is_binary(message) do
    if String.length(message) > @max_message_length do
      String.slice(message, 0, @max_message_length) <> "…"
    else
      message
    end
  end
end
