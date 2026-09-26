defmodule TymeslotWeb.Helpers.RedirectSanitizer do
  @moduledoc """
  Validates redirect paths to prevent open redirect vulnerabilities.

  The rules live in `Tymeslot.Security.RedirectPath`, which the domain also
  uses for OAuth `return_to` paths; see `Tymeslot.Security.RedirectPath.safe?/1`.
  """

  alias Tymeslot.Security.RedirectPath

  @doc """
  Returns `path` if it is a safe relative path, otherwise returns `default`.
  """
  @spec sanitize(String.t() | nil, String.t()) :: String.t()
  defdelegate sanitize(path, default), to: RedirectPath
end
