defmodule TymeslotWeb.Plugs.ThemePlug do
  @moduledoc """
  Plug to extract and assign theme_id from the request path for scheduling routes.
  """
  import Plug.Conn

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, _opts) do
    theme_id = extract_theme_id(conn.request_path)

    if theme_id do
      # Assign theme_id to both conn assigns and session for LiveView
      conn
      |> assign(:theme_id, theme_id)
      |> put_session(:theme_id, theme_id)
    else
      conn
    end
  end

  @spec extract_theme_id(String.t()) :: String.t() | nil
  defp extract_theme_id(path) do
    cond do
      # Match /scheduling/theme/:theme_id paths
      path =~ ~r{/scheduling/theme/(\d+)} ->
        [_, theme_id] = Regex.run(~r{/scheduling/theme/(\d+)}, path)
        theme_id

      # Match /theme/:theme_id paths (for demo routes)
      path =~ ~r{^/theme/(\d+)} ->
        [_, theme_id] = Regex.run(~r{^/theme/(\d+)}, path)
        theme_id

      true ->
        nil
    end
  end
end
