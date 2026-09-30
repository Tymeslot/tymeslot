defmodule Tymeslot.Infrastructure.ErrorTracking.HandledError do
  @moduledoc """
  Carries a failure that was not an exception (an `{:error, reason}` the code
  handled but did not expect) into ErrorTracker, which stores exceptions.

  ErrorTracker groups occurrences into one error by the exception module and
  the top application frame of the stacktrace; the message is stored with the
  error when it is first seen and with each occurrence. So the message here is
  the reason's *shape*, never its data: atoms and struct modules are kept,
  every other value is replaced by `_`. `{:http_error, 503, "Service
  Unavailable"}` reads `{:http_error, _, _}`, and a later `{:http_error, 500,
  "Internal"}` from the same call site is recognisably the same failure. The
  full reason, bounded and with the values of sensitive keys redacted, is kept
  in `reason` for the occurrence's context: once inspected it is a string, in
  which the Filter can no longer see keys.
  """

  alias Tymeslot.Infrastructure.Logging.MetadataRedactor

  defexception [:reason, :message]

  @type t :: %__MODULE__{reason: String.t(), message: String.t()}

  # Deep enough to tell `{:error, {:http, 500}}` from `{:error, :timeout}`,
  # shallow enough that the message stays a short title.
  @shape_depth 2
  @inspect_opts [limit: 20, printable_limit: 200, width: :infinity]

  @impl Exception
  def exception(reason) do
    %__MODULE__{
      reason: reason |> MetadataRedactor.redact() |> bounded_inspect(),
      message: shape(reason, @shape_depth)
    }
  end

  @doc """
  Renders any term with `inspect/2` bounded in collection length and string
  size, so a large reason cannot swell a log line or an occurrence.
  """
  @spec bounded_inspect(term()) :: String.t()
  def bounded_inspect(term), do: inspect(term, @inspect_opts)

  defp shape(atom, _depth) when is_atom(atom), do: inspect(atom)
  defp shape(%module{}, _depth), do: "%" <> inspect(module) <> "{}"
  defp shape(_term, 0), do: "_"

  defp shape(tuple, depth) when is_tuple(tuple) do
    elements = tuple |> Tuple.to_list() |> Enum.map_join(", ", &shape(&1, depth - 1))
    "{" <> elements <> "}"
  end

  defp shape(map, _depth) when is_map(map), do: "%{...}"
  defp shape(list, _depth) when is_list(list), do: "[...]"
  defp shape(binary, _depth) when is_binary(binary), do: "\"...\""
  defp shape(_other, _depth), do: "_"
end
